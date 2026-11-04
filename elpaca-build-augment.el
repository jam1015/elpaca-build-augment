;;; elpaca-build-augment.el --- Replay ELPA build steps under Elpaca -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jordan Mandel

;; Author: Jordan Mandel
;; Keywords: convenience
;; Package-Requires: ((emacs "27.1"))
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
;; re-download the bundled ELPA snapshots.  To exempt a specific
;; package from augmentation, just declare its `:build' yourself in
;; the `(elpaca ...)' / `(use-package ... :ensure (...))' form -- the
;; hook skips any recipe that already carries a `:build' field.

;;; Code:

;; When this file is byte-compiled by Elpaca, the compile subprocess
;; runs with no Elpaca on `load-path' -- Elpaca filters its own name
;; out of Package-Requires because it is bootstrapped, not package-
;; managed.  Our build dir sits as a sibling of Elpaca's own build dir
;; under <elpaca-builds-directory>, so adding "../elpaca" relative to
;; our file lets the compiler find it.  At runtime the user has
;; already loaded Elpaca (in order to call us), so this is a no-op.
(eval-when-compile
  (let ((here (or (and (boundp 'byte-compile-current-file) byte-compile-current-file)
                  load-file-name
                  buffer-file-name)))
    (when here
      (let ((sibling (expand-file-name "../elpaca"
                                       (file-name-directory here))))
        (when (file-directory-p sibling)
          (add-to-list 'load-path sibling))))))

(require 'elpaca)
(require 'cl-lib)
(require 'url)

(defgroup elpaca-build-augment nil
  "Blanket build-step contributions for Elpaca."
  :group 'elpaca
  :prefix "elpaca-build-augment-")

(defcustom elpaca-build-augment-cache-dir
  (expand-file-name "elpaca-build-augment-cache/" user-emacs-directory)
  "Directory holding cached ELPA metadata snapshots.
Lives under `user-emacs-directory' (not under the package's build
dir) so it survives package upgrades.  Populated on first use by
fetching from upstream; refreshable via `elpaca-build-augment-refresh'."
  :type 'directory)

(defconst elpaca-build-augment--sources-emacsmirror
  '((gnu
     :file "gnu-elpa-packages"
     :url "https://raw.githubusercontent.com/emacsmirror/gnu_elpa/refs/heads/main/elpa-packages")
    (nongnu
     :file "nongnu-elpa-packages"
     :url "https://raw.githubusercontent.com/emacsmirror/nongnu_elpa/refs/heads/main/elpa-packages"))
  "emacsmirror GitHub mirrors of the GNU/NonGNU ELPA `elpa-packages' files.
Default source set.  Backed by GitHub's CDN -- fast and stable.")

(defconst elpaca-build-augment--sources-savannah
  '((gnu
     :file "gnu-elpa-packages"
     :url "https://git.savannah.gnu.org/cgit/emacs/elpa.git/plain/elpa-packages")
    (nongnu
     :file "nongnu-elpa-packages"
     :url "https://git.savannah.gnu.org/cgit/emacs/nongnu-elpa.git/plain/elpa-packages"))
  "Upstream Savannah cgit sources for the `elpa-packages' files.
Authoritative but frequently overloaded -- cgit returns 502s from its
\"AI scraping proxies\" load-shedding page under traffic bursts, and
historical URL paths have shifted.  Available as an opt-in.")

(defcustom elpaca-build-augment-sources
  elpaca-build-augment--sources-emacsmirror
  "Alist of (LABEL PLIST) describing ELPA metadata sources.
PLIST keys: :file (basename cached under `elpaca-build-augment-cache-dir')
and :url (upstream fetch location).  Defaults to the emacsmirror GitHub
mirrors; Customize offers a Savannah preset or an arbitrary alist."
  :type `(choice
          (const :tag "emacsmirror GitHub mirrors (default, fast/stable)"
                 ,elpaca-build-augment--sources-emacsmirror)
          (const :tag "Savannah upstream (authoritative; may 502 under load)"
                 ,elpaca-build-augment--sources-savannah)
          (alist :tag "Custom alist"
                 :key-type symbol :value-type plist)))

(defcustom elpaca-build-augment-cache-metadata t
  "If non-nil, persist fetched ELPA metadata snapshots on disk.
With the default t, snapshots live under `elpaca-build-augment-cache-dir'
and are reused across Emacs sessions until `elpaca-build-augment-refresh'
is called.  With nil, no disk cache is kept: the metadata is fetched
once per Emacs session into an in-memory index and reused for every
package install in that session.  Call `elpaca-build-augment-refresh'
to force a refetch within a session."
  :type 'boolean)

(defcustom elpaca-build-augment-exclude-regexps
  '("\\`\\.git/" "/\\.git/" "\\`\\.git\\'"
    "\\`\\.github/" "\\`\\.gitlab" "\\`\\.gitignore\\'"
    "\\`\\.hg/" "\\`\\.svn/"
    "\\.elc\\'" "~\\'" "/#[^/]*#\\'" "/\\.#"
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
                                                 elpaca-build-augment-cache-dir)))
            elpaca-build-augment-sources))

(defun elpaca-build-augment--fetch-entries (src)
  "Fetch SRC's :url, validate, and return its parsed entries list.
Signals on an invalid response (e.g. 502 HTML page) so bad data can't
silently poison the in-memory index."
  (let ((url (plist-get (cdr src) :url)))
    (with-temp-buffer
      (url-insert-file-contents url)
      (goto-char (point-min))
      (skip-chars-forward " \t\n\r")
      (unless (eq (char-after) ?\;)
        (error "elpaca-build-augment: upstream response from %s is not a valid elpa-packages file (likely an HTTP error page)"
               url))
      (goto-char (point-min))
      (read (current-buffer)))))

(defun elpaca-build-augment--load-index-from-disk ()
  "Populate `--index' from on-disk snapshots, fetching if missing/invalid.
Self-healing: snapshots that don't look like an elpa-packages file
(e.g. a 502 HTML page left behind by an earlier failed fetch) are
deleted before refetch, so a transient upstream problem can't leave
the user with a cache that crashes the hook on every subsequent
package install."
  (dolist (src elpaca-build-augment-sources)
    (let ((path (expand-file-name (plist-get (cdr src) :file)
                                  elpaca-build-augment-cache-dir)))
      (when (and (file-readable-p path)
                 (not (elpaca-build-augment--valid-snapshot-p path)))
        (delete-file path))))
  (unless (elpaca-build-augment--snapshots-present-p)
    (elpaca-build-augment-refresh))
  (setq elpaca-build-augment--index nil)
  (dolist (src elpaca-build-augment-sources)
    (let ((path (expand-file-name (plist-get (cdr src) :file)
                                  elpaca-build-augment-cache-dir)))
      (when (file-readable-p path)
        (dolist (entry (with-temp-buffer
                         (insert-file-contents path)
                         (goto-char (point-min))
                         (read (current-buffer))))
          (push (cons (car entry) entry) elpaca-build-augment--index))))))

(defun elpaca-build-augment--load-index-from-network ()
  "Populate `--index' by fetching every source directly, without disk cache."
  (setq elpaca-build-augment--index nil)
  (dolist (src elpaca-build-augment-sources)
    (dolist (entry (elpaca-build-augment--fetch-entries src))
      (push (cons (car entry) entry) elpaca-build-augment--index))))

(defun elpaca-build-augment--load-index ()
  "Populate `elpaca-build-augment--index' per the caching settings."
  (if elpaca-build-augment-cache-metadata
      (elpaca-build-augment--load-index-from-disk)
    (elpaca-build-augment--load-index-from-network))
  elpaca-build-augment--index)

(defun elpaca-build-augment--entry (pkg)
  "Return the ELPA entry for PKG, loading the index if not already loaded."
  (unless elpaca-build-augment--index (elpaca-build-augment--load-index))
  (alist-get pkg elpaca-build-augment--index))

(defun elpaca-build-augment--entry-has-commands-p (entry)
  "Non-nil if ENTRY declares build commands we need to synthesize.
Only `:make', `:doc', and `:shell-command' require a synthesized shell
step.  Packaging fields (`:renames', `:lisp-dir', `:ignored-files',
`:excludes') are consumed directly by `--build-populate-files', which
runs for every ELPA package regardless of command presence."
  (let ((p (cdr entry)))
    (or (plist-get p :make)
        (plist-get p :doc)
        (plist-get p :shell-command))))

(defun elpaca-build-augment--doc-command (doc)
  "Return a shell command string that builds an .info from DOC.
DOC is a path relative to the package root.  Dispatches on extension:

  .texi / .texinfo  -> cd into DOC's dir, run makeinfo.  cd is needed
                       so @include paths resolve correctly (GNU texinfo
                       7.x resolves relative to CWD).
  .org              -> cd into DOC's dir, run an Emacs batch subprocess
                       that loads ox-texinfo, exports DOC to .texi via
                       `org-texinfo-export-to-texinfo', then runs
                       makeinfo on the produced file.  Handles
                       README.org-style :doc entries (corfu, consult,
                       vertico, many others).

Returns nil for unrecognized extensions."
  (let* ((dir (file-name-directory doc))
         (base (file-name-nondirectory doc))
         (ext (file-name-extension base))
         (info (concat (file-name-sans-extension base) ".info"))
         (cd-prefix (if dir
                        (format "cd %s && "
                                (shell-quote-argument (directory-file-name dir)))
                      "")))
    (cond
     ((member ext '("texi" "texinfo"))
      (format "%smakeinfo %s -o %s"
              cd-prefix
              (shell-quote-argument base)
              (shell-quote-argument info)))
     ((equal ext "org")
      (let ((eval-form
             (format
              (concat "(progn "
                      " (require 'ox-texinfo)"
                      " (find-file %S)"
                      " (let* ((org-babel-confirm-evaluate-answer-no t)"
                      "        (texi (org-texinfo-export-to-texinfo))"
                      "        (info (concat (file-name-sans-extension texi)"
                      "                      \".info\")))"
                      "   (unless (zerop (call-process \"makeinfo\" nil nil nil"
                      "                                \"--force\" texi \"-o\" info))"
                      "     (kill-emacs 1))))")
              base)))
        (format "%semacs -Q --batch --eval %s"
                cd-prefix
                (shell-quote-argument eval-form)))))))

(defun elpaca-build-augment--commands (entry)
  "Return the list of (PROGRAM ARG...) step forms synthesized from ENTRY."
  (let ((p (cdr entry)))
    (append
     (mapcar (lambda (c) `("sh" "-c" ,c))
             (elpaca-build-augment--as-list (plist-get p :shell-command)))
     (mapcar (lambda (tgt) `("make" ,tgt))
             (elpaca-build-augment--as-list (plist-get p :make)))
     (delq nil
           (mapcar (lambda (d)
                     (when-let* ((cmd (elpaca-build-augment--doc-command d)))
                       `("sh" "-c" ,cmd)))
                   (elpaca-build-augment--as-list (plist-get p :doc)))))))

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

(defun elpaca-build-augment--strip-lisp-dir (rel lisp-dir)
  "Strip LISP-DIR prefix from REL if present."
  (if (and lisp-dir
           (string-prefix-p (file-name-as-directory lisp-dir) rel))
      (substring rel (length (file-name-as-directory lisp-dir)))
    rel))

(defun elpaca-build-augment--apply-renames (rel renames)
  "Apply ELPA :renames spec RENAMES to source-relative REL.
RENAMES is a list of (FROM TO) pairs; the first FROM that is a prefix
of REL is replaced with TO.  Mirrors elpa-admin.el's packaging rename
step (e.g. corfu's `((\"extensions/\" \"\"))' flattens extensions/)."
  (or (cl-some (lambda (pair)
                 (let ((from (car pair)) (to (cadr pair)))
                   (when (and (stringp from) (string-prefix-p from rel))
                     (concat (or to "") (substring rel (length from))))))
               renames)
      rel))

(defun elpaca-build-augment--info-basename-counts (rels)
  "Return a hash table mapping each .info basename in RELS to its count."
  (let ((counts (make-hash-table :test #'equal)))
    (dolist (r rels counts)
      (when (string-match-p "\\.info\\(-[0-9]+\\)?\\'" r)
        (let ((base (file-name-nondirectory r)))
          (puthash base (1+ (gethash base counts 0)) counts))))))

(defun elpaca-build-augment--build-link-target (rel lisp-dir renames info-counts)
  "Map source-relative REL to its build-dir-relative target.
Applies RENAMES (ELPA :renames), then strips LISP-DIR, then flattens
any .info directory prefix (so `doc/foo.info' lands at build root
where `Info-directory-list' finds it), but only when its basename is
unique across the package -- colliding basenames keep their directory
prefix.  INFO-COUNTS is a basename->count hash for the whole file set."
  (let ((flat (elpaca-build-augment--strip-lisp-dir
               (elpaca-build-augment--apply-renames rel renames)
               lisp-dir)))
    (if (string-match-p "\\.info\\(-[0-9]+\\)?\\'" flat)
        (let ((base (file-name-nondirectory flat)))
          (if (> (gethash base info-counts 0) 1) flat base))
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
the ELPA entry's `:lisp-dir' and `:renames' fields by rewriting path
prefixes accordingly (so e.g. corfu's `extensions/' subdir flattens)."
  (let* ((src (elpaca<-source-dir e))
         (build (elpaca<-build-dir e))
         (pkg-name (or (elpaca<-package e)
                       (plist-get (elpaca<-recipe e) :package)))
         (entry (and pkg-name
                     (elpaca-build-augment--entry (intern pkg-name))))
         (extras (elpaca-build-augment--entry-exclude-regexps entry))
         (lisp-dir (plist-get (cdr entry) :lisp-dir))
         (renames (plist-get (cdr entry) :renames))
         (all (directory-files-recursively src ".*" nil
                                           (lambda (d)
                                             (not (string-match-p
                                                   "/\\.git\\(?:/\\|\\'\\)"
                                                   d)))))
         (kept (cl-loop for abs in all
                        for rel = (file-relative-name abs src)
                        unless (elpaca-build-augment--excluded-p rel extras)
                        collect (cons abs rel)))
         (info-counts (elpaca-build-augment--info-basename-counts
                       (mapcar (lambda (p)
                                 (elpaca-build-augment--strip-lisp-dir
                                  (elpaca-build-augment--apply-renames
                                   (cdr p) renames)
                                  lisp-dir))
                               kept)))
         (specs
          (cl-loop for (abs . rel) in kept
                   collect (cons abs
                                 (expand-file-name
                                  (elpaca-build-augment--build-link-target
                                   rel lisp-dir renames info-counts)
                                  build)))))
    (setf (elpaca<-files e) specs))
  (elpaca-continue e))

(defun elpaca-build-augment--recipe-hook (recipe)
  "Function on `elpaca-recipe-functions'.
Branches on the package's presence in GNU/NonGNU ELPA metadata:

- Entry present, declares `:make'/`:doc'/`:shell-command': synthesize
  the specific commands, then run `--build-populate-files' to mirror
  ELPA's \"ship everything in source\" packaging.
- Entry present, no build commands: run `--build-populate-files' only.
  ELPA's `elpa-admin.el' applies whole-source packaging to every entry,
  so merely appearing in `elpa-packages' qualifies a package for it.
  This is what gets non-elisp files (data tables, snippets, Scheme
  glue, images) into the build dir for packages that declare nothing
  beyond a `:url'.
- No entry: run `--build-scan-and-makeinfo' (MELPA-style heuristic
  that compiles any standalone .texi manuals it finds in source).

Skipped entirely for recipes that already carry an explicit `:build'
field (e.g. Org's menu entry), to avoid clobbering a maintainer-set
build pipeline."
  (when-let* ((pkg-name (plist-get recipe :package))
              (pkg (intern pkg-name))
              ((not (plist-member recipe :build))))
    (let* ((entry (elpaca-build-augment--entry pkg))
           (before-steps
            (cond
             ((and entry (elpaca-build-augment--entry-has-commands-p entry))
              (list (elpaca-build-augment--synthesize-step pkg entry)
                    'elpaca-build-augment--build-populate-files))
             (entry
              (list 'elpaca-build-augment--build-populate-files))
             (t
              (list 'elpaca-build-augment--build-scan-and-makeinfo)))))
      `(:build ((:not elpaca-build-docs)
                (:before elpaca-build-link ,@before-steps)
                (:after elpaca-build-link
                        elpaca-build-augment--queue-install-info))))))

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
  "Print the build steps that would be applied to PKG."
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
       ((and entry (elpaca-build-augment--entry-has-commands-p entry))
        (princ (format "ELPA entry:\n  %S\n\n" entry))
        (princ "ELPA-driven path -- synthesized steps (run in source dir):\n")
        (dolist (cmd (elpaca-build-augment--commands entry))
          (princ (format "  %s\n" (mapconcat #'identity cmd " "))))
        (princ "Followed by populate-files to mirror ELPA's packaging model.\n"))
       (entry
        (princ (format "ELPA entry (no build commands):\n  %S\n\n" entry))
        (princ "ELPA-driven path -- populate-files only.  Mirrors ELPA's\n")
        (princ "whole-source packaging so non-elisp files (data tables,\n")
        (princ "snippets, images, etc.) land in the build dir.\n"))
       (t
        (princ "No entry in GNU/NonGNU ELPA snapshots.\n\n")
        (princ "Generic path -- at install time, scan source for\n")
        (princ "standalone .texi files (any with @setfilename) and run\n")
        (princ "makeinfo on each from its own directory.  No-op if the\n")
        (princ "package ships no manual.\n"))))))

;;;###autoload
(defun elpaca-build-augment--valid-snapshot-p (path)
  "Non-nil if PATH exists and looks like an `elpa-packages' file.
A valid file is one whose first non-blank line starts with `;' (the
`;; -*- lisp-data -*-' header).  Guards against corrupted responses
(HTML error pages, truncated transfers, etc.) silently poisoning the
cache: `url-copy-file' saves whatever bytes come back, even an HTTP
502 page."
  (and (file-readable-p path)
       (> (file-attribute-size (file-attributes path)) 0)
       (with-temp-buffer
         (insert-file-contents path nil 0 256)
         (goto-char (point-min))
         (skip-chars-forward " \t\n\r")
         (eq (char-after) ?\;))))

(defun elpaca-build-augment-refresh ()
  "Re-download the elpa-packages snapshots from upstream.
Validates each response before overwriting the cache -- bad responses
(e.g. Savannah's 502 error pages) are discarded, not saved, so a
transient upstream failure can't poison the cache.

When `elpaca-build-augment-cache-metadata' is nil, no disk cache is in
use; this command just refetches straight into the in-memory index."
  (interactive)
  (cond
   ((not elpaca-build-augment-cache-metadata)
    (clrhash elpaca-build-augment--step-cache)
    (elpaca-build-augment--load-index-from-network)
    (message "elpaca-build-augment: refreshed %d entries (no disk cache)"
             (length elpaca-build-augment--index)))
   (t
    (elpaca-build-augment--refresh-disk-cache))))

(defun elpaca-build-augment--refresh-disk-cache ()
  "Refetch snapshots into `elpaca-build-augment-cache-dir'."
  (make-directory elpaca-build-augment-cache-dir t)
  (dolist (src elpaca-build-augment-sources)
    (let* ((plist (cdr src))
           (final (expand-file-name (plist-get plist :file)
                                    elpaca-build-augment-cache-dir))
           (tmp (concat final ".tmp"))
           (url (plist-get plist :url)))
      (message "elpaca-build-augment: fetching %s..." url)
      (url-copy-file url tmp 'ok-if-already-exists)
      (if (elpaca-build-augment--valid-snapshot-p tmp)
          (rename-file tmp final 'ok-if-already-exists)
        (delete-file tmp)
        (error "elpaca-build-augment: upstream response from %s is not a valid elpa-packages file (likely an HTTP error page); cache unchanged"
               url))))
  (clrhash elpaca-build-augment--step-cache)
  (elpaca-build-augment--load-index)
  (message "elpaca-build-augment: refreshed %d entries"
           (length elpaca-build-augment--index)))

(provide 'elpaca-build-augment)
;;; elpaca-build-augment.el ends here
