;;; elpaca-build-augment-test.el --- Compare Elpaca builds to package.el tarballs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jordan Mandel

;; Author: Jordan Mandel
;; Keywords: convenience
;; Package-Requires: ((emacs "27.1") (elpaca-build-augment "0.1.0"))
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

;;; Commentary:

;; Audit tool that answers: "for each package Elpaca built on my
;; machine, does it carry everything the matching package.el tarball
;; would have?"  Downloads the latest tarball from GNU/NonGNU/MELPA,
;; untars to a cache dir, and diffs the two file sets.  Elisp,
;; autoloads, pkg descriptors, and README/license noise are filtered
;; out so only build artifacts (.info, .sty, images, data files) show
;; up as "missing".
;;
;; Three entry points:
;;
;;   M-x elpaca-build-augment-test        -- completing-read one package
;;   M-x elpaca-build-augment-test-all    -- audit every queued package
;;   `elpaca-build-augment-test-watch'    -- defcustom list; after init,
;;                                           any watched package whose
;;                                           parity broke is reported
;;                                           in the *Messages* buffer.
;;
;; Enable with `(elpaca-build-augment-test-enable)' to install the
;; watch hook.  The other commands work without the hook.

;;; Code:

(require 'elpaca)
(require 'elpaca-build-augment)
(require 'cl-lib)
(require 'url)
(require 'tabulated-list)

(defgroup elpaca-build-augment-test nil
  "Audit Elpaca builds against package.el tarballs."
  :group 'elpaca-build-augment
  :prefix "elpaca-build-augment-test-")

(defcustom elpaca-build-augment-test-cache-dir
  (expand-file-name "elpaca-build-augment-test-cache/" user-emacs-directory)
  "Directory holding downloaded tarballs and their extracted contents."
  :type 'directory)

(defcustom elpaca-build-augment-test-archives
  '((gnu    . "https://elpa.gnu.org/packages/")
    (nongnu . "https://elpa.nongnu.org/nongnu/")
    (melpa  . "https://melpa.org/packages/"))
  "Alist of (LABEL . BASE-URL) for package.el archives, searched in order.
BASE-URL must end in a slash; `archive-contents' and `<pkg>-<ver>.tar'
are appended to it."
  :type '(alist :key-type symbol :value-type string))

(defcustom elpaca-build-augment-test-ignore-regexps
  '("\\.elc?\\'"
    "-autoloads\\.el\\'"
    "-pkg\\.el\\'"
    "\\`dir\\'" "\\`\\.dir-locals\\.el\\'"
    "\\`LICENSE\\'" "\\`COPYING\\(\\.LESSER\\)?\\'" "\\`COPYRIGHT\\'"
    "\\`README" "\\`NEWS" "\\`AUTHORS" "\\`ChangeLog" "\\`TODO"
    "\\.md\\'" "\\.rst\\'" "\\.org\\'" "\\.txt\\'"
    "\\.gitignore\\'" "\\.gitattributes\\'")
  "Regexps matched against *basenames*.  Matching files are not reported
as missing.  Elisp, autoloads, and docs/metadata that both installers
produce from the same source are excluded by default -- only genuine
build artifacts remain."
  :type '(repeat regexp))

(defvar elpaca-build-augment-test--archive-cache (make-hash-table :test #'eq)
  "Hash mapping archive label -> parsed `archive-contents' alist.")

(defcustom elpaca-build-augment-test-watch nil
  "List of package symbols to audit automatically after Elpaca finishes.
A one-line parity report is written to *Messages* for each.  Use
`elpaca-build-augment-test-enable' to install the hook."
  :type '(repeat symbol))

;;;; Archive fetch & lookup

(defun elpaca-build-augment-test--archive-contents (label)
  "Return parsed `archive-contents' for archive LABEL, fetching if needed."
  (or (gethash label elpaca-build-augment-test--archive-cache)
      (let* ((base (alist-get label elpaca-build-augment-test-archives))
             (url (concat base "archive-contents"))
             (contents
              (with-temp-buffer
                (condition-case err
                    (progn (url-insert-file-contents url)
                           (goto-char (point-min))
                           (read (current-buffer)))
                  (error (message "elpaca-build-augment-test: fetch %s failed: %s"
                                  url err)
                         nil)))))
        (when contents
          (puthash label (cdr contents) ; drop the leading version int
                   elpaca-build-augment-test--archive-cache))
        (gethash label elpaca-build-augment-test--archive-cache))))

(defun elpaca-build-augment-test--find-in-archives (pkg)
  "Return (LABEL VERSION-STRING KIND) for PKG, or nil if unavailable.
KIND is the symbol `tar' or `single' from archive-contents."
  (cl-loop for (label . _url) in elpaca-build-augment-test-archives
           for contents = (elpaca-build-augment-test--archive-contents label)
           for entry = (and contents (alist-get pkg contents))
           when entry
           return (list label
                        (mapconcat #'number-to-string
                                   (aref entry 0) ".")
                        (aref entry 3))))

;;;; Download & extract

(defun elpaca-build-augment-test--tarball-url (label pkg version kind)
  "Return the download URL for PKG VERSION in archive LABEL."
  (let ((base (alist-get label elpaca-build-augment-test-archives))
        (ext (if (eq kind 'single) "el" "tar")))
    (format "%s%s-%s.%s" base pkg version ext)))

(defun elpaca-build-augment-test--gc-stale (pkg keep-version)
  "Delete any cached PKG-* dir other than PKG-KEEP-VERSION.
Keeps the cache size bounded as archives roll new versions."
  (let ((root elpaca-build-augment-test-cache-dir)
        (keep (format "%s-%s" pkg keep-version))
        (prefix (format "%s-" pkg)))
    (when (file-directory-p root)
      (dolist (entry (directory-files root nil "\\`[^.]" t))
        (when (and (string-prefix-p prefix entry)
                   (not (equal entry keep))
                   (file-directory-p (expand-file-name entry root)))
          (delete-directory (expand-file-name entry root) t))))))

(defun elpaca-build-augment-test--extracted-dir (pkg version kind)
  "Return the local directory where PKG VERSION should be extracted.
If PKG is already cached at VERSION, skip the download; otherwise fetch
and extract.  Any cached PKG at a different version is deleted first."
  (let* ((root elpaca-build-augment-test-cache-dir)
         (dir  (expand-file-name (format "%s-%s" pkg version) root)))
    (unless (file-directory-p dir)
      (elpaca-build-augment-test--gc-stale pkg version)
      (make-directory root t)
      (let* ((info (elpaca-build-augment-test--find-in-archives pkg))
             (label (car info))
             (url (elpaca-build-augment-test--tarball-url
                   label pkg version kind))
             (tmp (make-temp-file "elpaca-build-augment-test-" nil
                                  (if (eq kind 'single) ".el" ".tar"))))
        (message "elpaca-build-augment-test: downloading %s..." url)
        (url-copy-file url tmp t)
        (make-directory dir t)
        (if (eq kind 'single)
            (copy-file tmp (expand-file-name (format "%s.el" pkg) dir) t)
          (let ((default-directory dir))
            (unless (zerop (call-process "tar" nil nil nil "xf" tmp
                                         "--strip-components=1"))
              (error "tar failed on %s" tmp))))
        (delete-file tmp)))
    dir))

;;;; Diff

(defun elpaca-build-augment-test--walk (dir)
  "Return basenames of regular files under DIR, filtered by ignore regexps."
  (let ((all (and (file-directory-p dir)
                  (directory-files-recursively
                   dir ".*" nil
                   (lambda (d) (not (string-match-p "/\\.git\\(/\\|\\'\\)" d)))))))
    (cl-remove-duplicates
     (cl-loop for abs in all
              for base = (file-name-nondirectory abs)
              unless (cl-some (lambda (re) (string-match-p re base))
                              elpaca-build-augment-test-ignore-regexps)
              collect base)
     :test #'equal)))

(defun elpaca-build-augment-test--elpaca-build-dir (pkg)
  "Return PKG's Elpaca build dir, or nil if not built."
  (let* ((name (if (symbolp pkg) (symbol-name pkg) pkg))
         (dir (expand-file-name name elpaca-builds-directory)))
    (and (file-directory-p dir) dir)))

(cl-defstruct elpaca-build-augment-test--result
  pkg archive version missing extra status pin)

(defun elpaca-build-augment-test--recipe-pin (pkg)
  "Return a short string describing how PKG is pinned, or nil.
Inspects the resolved Elpaca recipe for `:ref', `:tag', `:branch',
`:pin', or `:version'.  A pinned recipe means the installed source
is a specific commit/branch/tag, which may predate or diverge from
the latest tarball on the archive -- so any `GAP' row for such a
package may reflect version skew rather than a missing build step."
  (when (fboundp 'elpaca-get)
    (when-let* ((e (elpaca-get pkg))
                (recipe (elpaca<-recipe e)))
      (cond
       ((plist-get recipe :ref)     (format "ref:%s"     (plist-get recipe :ref)))
       ((plist-get recipe :tag)     (format "tag:%s"     (plist-get recipe :tag)))
       ((plist-get recipe :branch)  (format "branch:%s"  (plist-get recipe :branch)))
       ((plist-get recipe :version) (format "version:%s" (plist-get recipe :version)))
       ((plist-get recipe :pin)     "pinned")))))

(defun elpaca-build-augment-test--compare (pkg)
  "Return a result struct for PKG."
  (let* ((build (elpaca-build-augment-test--elpaca-build-dir pkg))
         (info (elpaca-build-augment-test--find-in-archives pkg))
         (pin (elpaca-build-augment-test--recipe-pin pkg)))
    (cond
     ((null build)
      (make-elpaca-build-augment-test--result
       :pkg pkg :pin pin :status 'not-built))
     ((null info)
      (make-elpaca-build-augment-test--result
       :pkg pkg :pin pin :status 'no-tarball))
     (t
      (pcase-let ((`(,label ,version ,kind) info))
        (condition-case err
            (let* ((tdir (elpaca-build-augment-test--extracted-dir
                          pkg version kind))
                   (tar-files (elpaca-build-augment-test--walk tdir))
                   (build-files (elpaca-build-augment-test--walk build))
                   (missing (cl-set-difference tar-files build-files
                                               :test #'equal))
                   (extra (cl-set-difference build-files tar-files
                                             :test #'equal)))
              (make-elpaca-build-augment-test--result
               :pkg pkg :archive label :version version :pin pin
               :missing missing :extra extra
               :status (if missing 'gap 'ok)))
          (error (make-elpaca-build-augment-test--result
                  :pkg pkg :archive (car info) :version (cadr info)
                  :pin pin
                  :status (cons 'error (error-message-string err))))))))))

;;;; Report buffer

(define-derived-mode elpaca-build-augment-test-mode tabulated-list-mode
  "EBA-Test"
  "Tabulated report of Elpaca-vs-tarball parity audits."
  (setq tabulated-list-format
        [("Package" 24 t)
         ("Archive" 8 t)
         ("Version" 18 t)
         ("Status"  10 t)
         ("Pinned"  18 t)
         ("Missing" 40 nil)])
  (setq tabulated-list-padding 1)
  (tabulated-list-init-header))

(defun elpaca-build-augment-test--status-string (status)
  (pcase status
    ('ok "ok")
    ('gap "GAP")
    ('not-built "not-built")
    ('no-tarball "no-tarball")
    (`(error . ,msg) (format "error:%s" msg))
    (_ (format "%s" status))))

(defun elpaca-build-augment-test--row (r)
  (let* ((pkg (elpaca-build-augment-test--result-pkg r))
         (missing (elpaca-build-augment-test--result-missing r))
         (status (elpaca-build-augment-test--result-status r)))
    (list pkg
          (vector (symbol-name pkg)
                  (if-let* ((a (elpaca-build-augment-test--result-archive r)))
                      (symbol-name a) "-")
                  (or (elpaca-build-augment-test--result-version r) "-")
                  (elpaca-build-augment-test--status-string status)
                  (or (elpaca-build-augment-test--result-pin r) "")
                  (if missing
                      (mapconcat #'identity (seq-take missing 6) ", ")
                    "")))))

(defun elpaca-build-augment-test--show (results)
  (let ((buf (get-buffer-create "*elpaca-build-augment-test*")))
    (with-current-buffer buf
      (elpaca-build-augment-test-mode)
      (setq tabulated-list-entries
            (mapcar #'elpaca-build-augment-test--row results))
      (tabulated-list-print))
    (pop-to-buffer buf)))

;;;; Entry points

(defun elpaca-build-augment-test--queued-packages ()
  "Return a sorted list of package symbols currently known to Elpaca."
  (sort (cl-loop for item in (elpaca--queued)
                 for sym = (car-safe item)
                 when sym collect sym)
        (lambda (a b) (string< (symbol-name a) (symbol-name b)))))

;;;###autoload
(defun elpaca-build-augment-test (pkg)
  "Audit one package: compare its Elpaca build dir against the tarball.
Always refetches `archive-contents' so the latest upstream version is
seen; the tarball itself is only re-downloaded when the version has
changed since the last audit."
  (interactive
   (list (intern (completing-read
                  "Package: "
                  (mapcar #'symbol-name
                          (elpaca-build-augment-test--queued-packages))
                  nil nil))))
  (clrhash elpaca-build-augment-test--archive-cache)
  (elpaca-build-augment-test--show
   (list (elpaca-build-augment-test--compare pkg))))

;;;###autoload
(defun elpaca-build-augment-test-all ()
  "Audit every package Elpaca has queued; render results in a buffer.
Always refetches `archive-contents' so the latest upstream version is
seen; each tarball is only re-downloaded when its version has changed
since the last audit."
  (interactive)
  (clrhash elpaca-build-augment-test--archive-cache)
  (let ((pkgs (elpaca-build-augment-test--queued-packages)))
    (elpaca-build-augment-test--show
     (cl-loop for p in pkgs
              do (message "elpaca-build-augment-test: %s..." p)
              collect (elpaca-build-augment-test--compare p)))))

(defun elpaca-build-augment-test--watch-run ()
  "Audit each `elpaca-build-augment-test-watch' package; message gaps."
  (clrhash elpaca-build-augment-test--archive-cache)
  (dolist (pkg elpaca-build-augment-test-watch)
    (let* ((r (elpaca-build-augment-test--compare pkg))
           (pin (elpaca-build-augment-test--result-pin r))
           (suffix (if pin (format " [pinned: %s -- gap may be version skew]" pin)
                     "")))
      (pcase (elpaca-build-augment-test--result-status r)
        ('gap (message "elpaca-build-augment-test: %s missing %s%s"
                       pkg
                       (mapconcat #'identity
                                  (elpaca-build-augment-test--result-missing r)
                                  ", ")
                       suffix))
        ('ok  (message "elpaca-build-augment-test: %s ok%s" pkg suffix))
        (_    nil)))))

;;;###autoload
(defun elpaca-build-augment-test-enable ()
  "Install an `elpaca-after-init-hook' that audits watched packages."
  (interactive)
  (add-hook 'elpaca-after-init-hook
            #'elpaca-build-augment-test--watch-run))

;;;###autoload
(defun elpaca-build-augment-test-disable ()
  "Remove the `elpaca-after-init-hook' audit."
  (interactive)
  (remove-hook 'elpaca-after-init-hook
               #'elpaca-build-augment-test--watch-run))

(provide 'elpaca-build-augment-test)
;;; elpaca-build-augment-test.el ends here
