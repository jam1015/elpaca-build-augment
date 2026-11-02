;;; elpaca-build-augment.el --- Replay ELPA build steps under Elpaca -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jordan Mandel

;; Author: Jordan Mandel
;; Keywords: convenience
;; Package-Requires: ((emacs "27.1") (elpaca "0"))
;; Version: 0.1.0

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; When Elpaca installs a package, it clones the source, byte-compiles
;; the elisp, and generates autoloads -- but it does not replay the
;; per-package build steps that GNU/NonGNU ELPA and MELPA run on their
;; build servers (make targets, makeinfo on .texi files, shell commands
;; that generate .el or data files).  For ~16% of ELPA packages this
;; means the Info manual, generated LaTeX styles, template-produced
;; elisp, or other build artifacts never land in the user's build dir.
;;
;; This library installs a single hook on `elpaca-recipe-functions'
;; that routes each package to one of two paths:
;;
;;   1. Metadata-driven: looks up the package in a bundled snapshot of
;;      GNU/NonGNU ELPA's `elpa-packages' file.  If that entry declares
;;      `:doc', `:make', or `:shell-command', the corresponding build
;;      steps are injected and ELPA's "ship everything in source"
;;      packaging model is mirrored:
;;
;;        :shell-command CMD   -> sh -c CMD   in source dir
;;        :make TGT            -> make TGT    in source dir
;;        :doc "D/F.texi"      -> cd D && makeinfo F.texi -o F.info
;;
;;   2. Heuristic: for MELPA-only packages (or ELPA entries without
;;      build fields), scan the source tree for standalone .texi
;;      manuals and run `makeinfo --force' on each.  @include fragments
;;      are detected and skipped.
;;
;; Recipes that already declare `:build' are left untouched.
;;
;; Enable with:
;;
;;   (require 'elpaca-build-augment)
;;   (elpaca-build-augment-enable)
;;
;; Use `M-x elpaca-build-augment-explain' to see which steps would be
;; injected for a package, and `M-x elpaca-build-augment-refresh' to
;; re-download the bundled ELPA snapshots.  Per-package escape-hatch
;; recipe overrides live in `elpaca-build-augment-overrides'.

;;; Code:

(require 'elpaca)
(require 'cl-lib)
(require 'url)

(defgroup elpaca-build-augment nil
  "Blanket build-step contributions for Elpaca."
  :group 'elpaca
  :prefix "elpaca-build-augment-")

(defcustom elpaca-build-augment-data-dir
  (expand-file-name "elpaca-build-augment/" user-emacs-directory)
  "Directory holding cached ELPA metadata snapshots.
Lives under `user-emacs-directory' (not under the package's build
dir) so it survives package upgrades.  Populated on first use by
fetching from upstream; refreshable via `elpaca-build-augment-refresh'."
  :type 'directory)

(defcustom elpaca-build-augment-sources
  ;; Note: these are the post-redirect canonical URLs.  Savannah's
  ;; `git.savannah.gnu.org' bounces to `cgit.git.savannah.gnu.org' via
  ;; 301, which `url-copy-file' in batch Emacs doesn't always follow
  ;; cleanly.  Pointing at the final hostname avoids the redirect.
  '((gnu
     :file "gnu-elpa-packages"
     :url "https://cgit.git.savannah.gnu.org/cgit/emacs/elpa.git/plain/elpa-packages")
    (nongnu
     :file "nongnu-elpa-packages"
     :url "https://cgit.git.savannah.gnu.org/cgit/emacs/nongnu.git/plain/elpa-packages"))
  "Alist of (LABEL PLIST) describing ELPA metadata sources.
PLIST keys: :file (basename cached under `elpaca-build-augment-data-dir')
and :url (upstream fetch location)."
  :type '(alist :key-type symbol :value-type plist))

(defcustom elpaca-build-augment-overrides nil
  "Alist of (PACKAGE . RECIPE-PLIST) escape-hatch overrides.
Merged on top of the auto-synthesized recipe for PACKAGE.  Normally
unused -- the hook mirrors ELPA's \"ship everything in source\"
packaging model, which captures non-elisp assets without per-package
tuning.  Populate this only for packages that still need surgery."
  :type '(alist :key-type symbol :value-type plist))

(defcustom elpaca-build-augment-exclude-regexps
  '("\\`\\.git/" "/\\.git/" "\\`\\.git\\'"
    "\\`\\.github/" "\\`\\.gitlab" "\\`\\.gitignore\\'"
    "\\`\\.hg/" "\\`\\.svn/"
    "\\.elc\\'" "~\\'" "/#[^/]*#\\'" "/\\.#"
    "\\`tests?/" "/tests?/" "-tests?\\.el\\'"
    "\\`\\.elpaignore\\'" "\\`\\.dir-locals\\.el\\'"
    "\\`LICENSE\\'" "\\`COPYING\\(\\.LESSER\\)?\\'"
    "\\`ChangeLog\\." "\\`README" "-pkg\\.el\\'")
  "Regexps matched against source-relative paths to drop files from the
whole-source `:files' set.  Mirrors elpa-admin.el's exclusion set."
  :type '(repeat regexp))

(defvar elpaca-build-augment--index nil
  "Alist mapping package symbol to its elpa-packages entry.
Populated lazily by `elpaca-build-augment--load-index'.")

(defvar elpaca-build-augment--step-cache (make-hash-table :test #'eq)
  "Cache of synthesized build-step function symbols per package.")

(defun elpaca-build-augment--as-list (x)
  "Return X if list, (list X) if non-nil scalar, else nil."
  (cond ((null x) nil) ((listp x) x) (t (list x))))

(defun elpaca-build-augment--snapshots-present-p ()
  "Non-nil if every configured source has a cached file on disk."
  (cl-every (lambda (src)
              (file-readable-p (expand-file-name (plist-get (cdr src) :file)
                                                 elpaca-build-augment-data-dir)))
            elpaca-build-augment-sources))

(defun elpaca-build-augment--load-index ()
  "Read cached snapshots into `elpaca-build-augment--index'.
If no cached snapshots exist yet, fetch them from upstream first.
This makes the data dir a locally-constructed artifact: the package
ships no metadata, only the elisp that fetches and caches it."
  (unless (elpaca-build-augment--snapshots-present-p)
    (elpaca-build-augment-refresh))
  (setq elpaca-build-augment--index nil)
  (dolist (src elpaca-build-augment-sources)
    (let ((path (expand-file-name (plist-get (cdr src) :file)
                                  elpaca-build-augment-data-dir)))
      (when (file-readable-p path)
        (dolist (entry (with-temp-buffer
                         (insert-file-contents path)
                         (goto-char (point-min))
                         (read (current-buffer))))
          (push (cons (car entry) entry) elpaca-build-augment--index)))))
  elpaca-build-augment--index)

(defun elpaca-build-augment--entry (pkg)
  "Return the ELPA entry for PKG, loading the index if needed."
  (unless elpaca-build-augment--index (elpaca-build-augment--load-index))
  (alist-get pkg elpaca-build-augment--index))

(defun elpaca-build-augment--entry-needs-help-p (entry)
  "Non-nil if ENTRY declares at least one build-step field."
  (let ((p (cdr entry)))
    (or (plist-get p :make)
        (plist-get p :doc)
        (plist-get p :shell-command))))

(defun elpaca-build-augment--doc-command (texi)
  "Return a shell command string that runs makeinfo on TEXI.
TEXI is a path relative to the package root.  The command cds into
TEXI's directory before invoking makeinfo so that @include paths
resolve correctly (GNU texinfo 7.x resolves relative to CWD)."
  (let* ((dir (file-name-directory texi))
         (base (file-name-nondirectory texi))
         (info (concat (file-name-sans-extension base) ".info")))
    (if dir
        (format "cd %s && makeinfo %s -o %s"
                (shell-quote-argument (directory-file-name dir))
                (shell-quote-argument base)
                (shell-quote-argument info))
      (format "makeinfo %s -o %s"
              (shell-quote-argument base)
              (shell-quote-argument info)))))

(defun elpaca-build-augment--commands (entry)
  "Return the list of (PROGRAM ARG...) step forms synthesized from ENTRY."
  (let ((p (cdr entry)))
    (append
     (mapcar (lambda (c) `("sh" "-c" ,c))
             (elpaca-build-augment--as-list (plist-get p :shell-command)))
     (mapcar (lambda (tgt) `("make" ,tgt))
             (elpaca-build-augment--as-list (plist-get p :make)))
     (mapcar (lambda (d) `("sh" "-c" ,(elpaca-build-augment--doc-command d)))
             (elpaca-build-augment--as-list (plist-get p :doc))))))

(defun elpaca-build-augment--synthesize-step (pkg entry)
  "Return a build-step function symbol for PKG, defining it if needed.
Uses `elpaca-defscript' to generate a function that invokes each of
PKG's synthesized shell commands in order, in the package source dir."
  (or (gethash pkg elpaca-build-augment--step-cache)
      (let ((sym (intern (format "elpaca-build-augment--build-%s" pkg)))
            (commands (elpaca-build-augment--commands entry)))
        (eval `(elpaca-defscript ,sym (:type system :dir source)
                 ,@commands)
              lexical-binding)
        (puthash pkg sym elpaca-build-augment--step-cache)
        sym)))

(defun elpaca-build-augment--queue-install-info (e)
  "Build step: queue `elpaca--install-info' onto E's remaining steps."
  (push 'elpaca--install-info (elpaca<-build-steps e))
  (elpaca-continue e))

(defun elpaca-build-augment--excluded-p (relpath entry-extras)
  "Non-nil if RELPATH matches any configured exclusion regexp.
ENTRY-EXTRAS is a list of additional regexps from the ELPA entry."
  (cl-some (lambda (re) (string-match-p re relpath))
           (append elpaca-build-augment-exclude-regexps entry-extras)))

(defun elpaca-build-augment--entry-exclude-regexps (entry)
  "Return regexps derived from ENTRY's :ignored-files and :excludes."
  (let* ((plist (cdr entry))
         (patterns (append (elpaca-build-augment--as-list
                            (plist-get plist :ignored-files))
                           (elpaca-build-augment--as-list
                            (plist-get plist :excludes)))))
    (mapcar (lambda (p) (concat "\\`" (regexp-quote p) "\\'")) patterns)))

(defun elpaca-build-augment--build-link-target (rel lisp-dir)
  "Map source-relative REL to its build-dir-relative target.
Flattens two kinds of prefix per ELPA's packaging conventions:
LISP-DIR (so `lisp/foo.el' lands at build root as `foo.el') and
any directory prefix on an .info file (so `doc/foo.info' lands at
build root as `foo.info', where `Info-directory-list' finds it)."
  (let ((flat
         (if (and lisp-dir
                  (string-prefix-p (file-name-as-directory lisp-dir) rel))
             (substring rel (length (file-name-as-directory lisp-dir)))
           rel)))
    (if (string-match-p "\\.info\\(-[0-9]+\\)?\\'" flat)
        (file-name-nondirectory flat)
      flat)))

(defun elpaca-build-augment--texi-output-name (file)
  "Return the .info basename that makeinfo would produce from FILE.
If FILE declares `@setfilename', use that; otherwise, if FILE begins
with `\\\\input texinfo' (= standalone manual), fall back to the
.texi's own basename.  Returns nil for `@include' fragments (which
have neither preamble)."
  (with-temp-buffer
    (insert-file-contents file nil 0 4096)
    (goto-char (point-min))
    (cond
     ((re-search-forward "^@setfilename[ \t]+\\(\\S-+\\)" nil t)
      (file-name-nondirectory (match-string 1)))
     ((progn (goto-char (point-min))
             (re-search-forward "^\\\\input[ \t]+texinfo" nil t))
      (concat (file-name-sans-extension (file-name-nondirectory file))
              ".info")))))

(defun elpaca-build-augment--build-scan-and-makeinfo (e)
  "Build step: find standalone .texi files in E's source and makeinfo them.
Mirrors MELPA's build harness without requiring any upstream metadata:
walks the source tree, runs makeinfo from each file's own directory
(so @include paths resolve), captures split output files, and appends
the produced .info paths to `elpaca<-files' with build-root targets.
Falls silent when the package ships no standalone .texi files."
  (let* ((src (elpaca<-source-dir e))
         (build (elpaca<-build-dir e))
         (texi-files
          (directory-files-recursively
           src "\\.texi\\(nfo\\)?\\'" nil
           (lambda (d)
             (not (string-match-p "/\\.git\\(?:/\\|\\'\\)" d)))))
         (new-pairs '()))
    (dolist (texi texi-files)
      (when-let* ((info-name (elpaca-build-augment--texi-output-name texi))
                  (default-directory (file-name-directory texi))
                  (base (file-name-nondirectory texi))
                  ;; --force makes makeinfo still produce output in the
                  ;; face of recoverable errors (duplicate @node, etc.);
                  ;; several real-world MELPA packages (e.g. el-autoyas)
                  ;; have texi that strict makeinfo refuses to compile.
                  ((zerop (call-process "makeinfo" nil nil nil
                                        "--force"
                                        base "-o" info-name))))
        (dolist (split (directory-files
                        default-directory t
                        (concat "\\`" (regexp-quote info-name)
                                "\\(-[0-9]+\\)?\\'")))
          (push (cons split
                      (expand-file-name (file-name-nondirectory split) build))
                new-pairs))))
    (when new-pairs
      (unless (elpaca<-files e)
        (setf (elpaca<-files e) (elpaca--files e)))
      (setf (elpaca<-files e)
            (cl-remove-duplicates (append (elpaca<-files e) new-pairs)
                                  :test #'equal :from-end t))))
  (elpaca-continue e))

(defun elpaca-build-augment--build-populate-files (e)
  "Build step: scan source dir and set `elpaca<-files' to a flat spec.
Mirrors ELPA's \"ship everything in source minus junk\" model so that
non-elisp assets (etc/, images/, *.ti, etc.) land in the build dir
without any per-package `:files' tuning.  Produces file-level pairs,
not directory-level ones, so Elpaca's autoload walker (which does not
descend directory symlinks) still finds .el files in subdirs.  Honors
the ELPA entry's `:lisp-dir' field by flattening that prefix."
  (let* ((src (elpaca<-source-dir e))
         (build (elpaca<-build-dir e))
         (pkg-name (or (elpaca<-package e)
                       (plist-get (elpaca<-recipe e) :package)))
         (entry (and pkg-name
                     (elpaca-build-augment--entry (intern pkg-name))))
         (extras (elpaca-build-augment--entry-exclude-regexps entry))
         (lisp-dir (plist-get (cdr entry) :lisp-dir))
         (all (directory-files-recursively src ".*" nil
                                           (lambda (d)
                                             (not (string-match-p
                                                   "/\\.git\\(?:/\\|\\'\\)"
                                                   d)))))
         (specs
          (cl-loop for abs in all
                   for rel = (file-relative-name abs src)
                   unless (elpaca-build-augment--excluded-p rel extras)
                   collect (cons abs
                                 (expand-file-name
                                  (elpaca-build-augment--build-link-target
                                   rel lisp-dir)
                                  build)))))
    (setf (elpaca<-files e) specs))
  (elpaca-continue e))

(defun elpaca-build-augment--recipe-hook (recipe)
  "Function on `elpaca-recipe-functions'.
Branches on whether the package has GNU/NonGNU ELPA build metadata:

- With ELPA metadata declaring `:make', `:doc', or `:shell-command':
  inject the specific commands and mirror ELPA's \"ship everything\"
  packaging via `elpaca-build-augment--build-populate-files'.
- Otherwise: inject a filesystem-driven makeinfo pass that handles
  packages whose only build need is compiling .texi manuals (the
  common MELPA case).  Falls silent for packages shipping no .texi.

Skipped entirely for recipes that already carry an explicit `:build'
field (e.g. Org's menu entry), to avoid clobbering a maintainer-set
build pipeline."
  (when-let* ((pkg-name (plist-get recipe :package))
              (pkg (intern pkg-name))
              ((not (plist-member recipe :build))))
    (let* ((entry (elpaca-build-augment--entry pkg))
           (overrides (alist-get pkg elpaca-build-augment-overrides))
           (elpa-help (and entry
                           (elpaca-build-augment--entry-needs-help-p entry)))
           (before-steps
            (if elpa-help
                (list (elpaca-build-augment--synthesize-step pkg entry)
                      'elpaca-build-augment--build-populate-files)
              (list 'elpaca-build-augment--build-scan-and-makeinfo))))
      (append
       `(:build ((:not elpaca-build-docs)
                 (:before elpaca-build-link ,@before-steps)
                 (:after elpaca-build-link
                         elpaca-build-augment--queue-install-info)))
       overrides))))

;;;###autoload
(defun elpaca-build-augment-enable ()
  "Install the contrib build-step hook."
  (interactive)
  (add-hook 'elpaca-recipe-functions #'elpaca-build-augment--recipe-hook))

;;;###autoload
(defun elpaca-build-augment-disable ()
  "Remove the contrib build-step hook."
  (interactive)
  (remove-hook 'elpaca-recipe-functions #'elpaca-build-augment--recipe-hook))

;;;###autoload
(defun elpaca-build-augment-explain (pkg)
  "Print the build steps and overrides that would be applied to PKG."
  (interactive
   (list (intern (completing-read "Package: "
                                  (progn (unless elpaca-build-augment--index
                                           (elpaca-build-augment--load-index))
                                         elpaca-build-augment--index)
                                  nil nil))))
  (let ((entry (elpaca-build-augment--entry pkg)))
    (with-output-to-temp-buffer "*elpaca-build-augment*"
      (princ (format "Package: %s\n\n" pkg))
      (cond
       ((and entry (elpaca-build-augment--entry-needs-help-p entry))
        (princ (format "ELPA entry:\n  %S\n\n" entry))
        (princ "ELPA-driven path -- synthesized steps (run in source dir):\n")
        (dolist (cmd (elpaca-build-augment--commands entry))
          (princ (format "  %s\n" (mapconcat #'identity cmd " "))))
        (princ "Followed by populate-files to mirror ELPA's packaging model.\n"))
       (t
        (if entry
            (princ (format "ELPA entry (no build fields):\n  %S\n\n" entry))
          (princ "No entry in bundled GNU/NonGNU ELPA snapshots.\n\n"))
        (princ "Generic path -- at install time, scan source for\n")
        (princ "standalone .texi files (any with @setfilename) and run\n")
        (princ "makeinfo on each from its own directory.  No-op if the\n")
        (princ "package ships no manual.\n")))
      (when-let* ((overrides (alist-get pkg elpaca-build-augment-overrides)))
        (princ (format "\nUser overrides from `elpaca-build-augment-overrides':\n  %S\n"
                       overrides))))))

;;;###autoload
(defun elpaca-build-augment-refresh ()
  "Re-download the bundled elpa-packages snapshots from upstream."
  (interactive)
  (make-directory elpaca-build-augment-data-dir t)
  (dolist (src elpaca-build-augment-sources)
    (let* ((plist (cdr src))
           (dest (expand-file-name (plist-get plist :file)
                                   elpaca-build-augment-data-dir))
           (url (plist-get plist :url)))
      (message "elpaca-build-augment: fetching %s..." url)
      (url-copy-file url dest 'ok-if-already-exists)))
  (clrhash elpaca-build-augment--step-cache)
  (elpaca-build-augment--load-index)
  (message "elpaca-build-augment: refreshed %d entries"
           (length elpaca-build-augment--index)))

(provide 'elpaca-build-augment)
;;; elpaca-build-augment.el ends here
