;;; make package archive files --- -*- lexical-binding: t -*-

;;; Commentary

;; Manage the archive-contents file. The archive-contents is an index
;; of the packages in the repository in list form. Each ELPA client
;; using marmalade downloads the archive-contents to know what
;; packages are available on marmalade.

;; The internal representation of the index is a hash table. The hash
;; is never served directly to an ELPA client though, it is cached to
;; an archive-contents list representation in a file and the file is
;; served.

;; Many archive-contents cache files might exist as the hash table is
;; written to a new file each time it is updated. Proxying techniques
;; are used to ensure that marmalade serves the newest
;; archive-contents file to clients.

;;; Notes

;; The code here isn't cleanly namespaced with marmalade/archive or
;; anything like that. But why should it? it's ridiculous to have to
;; do that all the time with a single package.

(require 'rx)
(require 'package)
(require 'marmalade-customs)
(require 'dash)

(defun marmalade/archive-file (&optional lisp)
  "Get the marmalade archive file name.

If optional LISP is `t', the LISP version of the file is
returned."
  (let ((base
         (concat
          (file-name-as-directory marmalade-package-store-dir)
          "archive-contents")))
    (if lisp (concat base ".el") base)))

;; Directory root mangling code

(defun marmalade/list-files-string (root)
  "Make the marmalade file list buffer for ROOT.

The file list buffer is a list of all files under the ROOT.  We
just use unix find for this right now.  But it could be done with
emacs-lisp as well of course.

The files are then filtered by `marmalade/list-files'."
  (let ((marmalade-list-buffer (get-buffer " *marmalade-list*")))
    (if (bufferp marmalade-list-buffer)
        (with-current-buffer marmalade-list-buffer
          (buffer-string))
        ;; Else use lisp to do it
        (let (done
              (process (start-process-shell-command
                        "marmalade/find"
                        (generate-new-buffer " *marmalade-list*")
                        (concat "find " root " -type f"))))
          (set-process-sentinel
           process
           (lambda (proc status)
             (when (equal status "finished\n")
               (with-current-buffer (process-buffer proc)
                 (setq done (buffer-string))))))
          (while (not done)
            (message "busy waiting in marmalade/list-files-string")
            (accept-process-output process 1))
          ;; And finally return done, the output from the process
          done))))

(defun marmalade/list-dir (root)
  "EmacsLisp version of package find list dir.

The parent directory of ROOT is stripped off the resulting
files."
  (let* ((root-dir (file-name-as-directory
                    (expand-file-name root)))
         (re (concat "^" (expand-file-name
                          (concat root-dir "..")) "\\(.*\\)"))
         (package-dir-list
          (--filter
           ;; no el files at this level
           (not (string-match-p "\\.el$" it)) 
           (directory-files root-dir t "^[^.].*")))
         (version-dir-list
          (loop for package-dir in package-dir-list
             collect (directory-files package-dir t "^[^.].*"))))
    (--map
     (when (string-match re it) (match-string 1 it))
     (-flatten
      (loop for p in (-flatten version-dir-list)
         collect (directory-files p t "^[^.].*"))))))

(defun marmalade/list-files (root)
  "Turn ROOT into a list of maramalade meta data.

ROOT is present on the filename."
  ;; (split-string (marmalade/list-files-string root) "\n")
  (let ((root-parent
         (expand-file-name
          (concat (file-name-as-directory root) "..")))
        (dir-list (marmalade/list-dir root)))
    (loop for filename in dir-list
       if (string-match
           (concat
            "^.*/\\([A-Za-z0-9-]+\\)/"
            "\\([0-9.]+\\)/"
            "\\([A-Za-z0-9.-]+\\).\\(el\\|tar\\)$")
           filename)
       collect
         (list
          (concat root-parent filename)
          ;; (match-string 1 filename)
          ;; (match-string 2 filename)
          ;; (match-string 3 filename)
          ;; The type
          (match-string 4 filename)))))

(defun marmalade/commentary-handle (buffer)
  "package.el does not handle bad commentary declarations.

People forget to add the ;;; Code marker ending the commentary.
This does a substitute."
  (with-current-buffer buffer
    (goto-char (point-min))
    ;; This is where we could remove the ;; from the start of the
    ;; commentary lines
    (let ((commentary-pos
           (re-search-forward "^;;; Commentary" nil t)))
      (if commentary-pos
          (buffer-substring-no-properties
           (+ commentary-pos 3)
           (- (re-search-forward "^;+ .*\n[ \n]+(" nil t) 2))
          "No commentary."))))

(defun marmalade/package-buffer-info (buffer)
  "Do `package-buffer-info' but with fixes."
  (with-current-buffer buffer
    (let ((pkg-info (package-buffer-info)))
      (unless (save-excursion (re-search-forward "^;;; Code:"  nil t))
        (aset pkg-info 4 (marmalade/commentary-handle (current-buffer))))
      pkg-info)))

(defun marmalade/package-file-info (filename)
  "Wraps `marmalade/package-buffer-info' with FILENAME getting."
  (let ((buffer (let ((enable-local-variables nil))
                  (find-file-noselect filename))))
    (unwind-protect
         (marmalade/package-buffer-info buffer)
      ;; FIXME - We should probably only kill it if we didn't have it
      ;; before
      (kill-buffer buffer))))

(defun marmalade/package-stuff (filename type)
  "Make the FILENAME a package of TYPE.

This reads in the FILENAME.  But it does it safely and it also
kills it.

It returns a cons of `single' or `multi' and "
  (let ((ptype
         (case (intern type)
           (el 'single)
           (tar 'tar))))
    (cons
     ptype
     (case ptype
       (single (marmalade/package-file-info filename))
       (tar (package-tar-file-info filename))))))

(defun marmalade/root->archive (root)
  "For ROOT make an archive list."
  (let ((files-list (marmalade/list-files root)))
    (loop for (filename type) in files-list
       with package-stuff
       do
         (setq package-stuff
               (condition-case err
                   (marmalade/package-stuff filename type)
                 (error nil)))
       if package-stuff
       collect package-stuff)))

(defun marmalade/packages-list->archive-list (packages-list)
  "Turn the list of packages into an archive list."
  ;; elpakit has a version of this
  (loop for (type . package) in packages-list
     collect
       (cons
        (intern (elt package 0)) ; name
        (vector (version-to-list (elt package 3)) ; version list
                (elt package 1) ; requirements
                (elt package 2) ; doc string
                type))))

;; Handle the cache

(defvar marmalade/archive-cache (make-hash-table :test 'equal)
  "The cache of all current packages.")

(defun marmalade/archive-cache-fill (root)
  "Fill the cache by reading the ROOT."
  (let ((typed-package-list (marmalade/root->archive root)))
    (loop
       for (type . package) in typed-package-list
       do (let* ((package-name (elt package 0))
                 (current-package
                  (gethash package-name marmalade/archive-cache)))
            (if current-package
                ;; Put it only if it's a newer version
                (let ((current-version (elt (cdr current-package) 3))
                      (new-version (elt package 3)))
                  (when (version< current-version new-version)
                    (puthash
                     package-name (cons type package)
                     marmalade/archive-cache)))
                ;; Else just put it
                (puthash
                 package-name (cons type package)
                 marmalade/archive-cache))))))

(defun marmalade/cache->package-archive ()
  "Turn the cache into the package-archive list.

Returns the Lisp form of the archive which is sent (almost
directly) back to ELPA clients.

If the cache is empty this returns `nil'."
  (marmalade/packages-list->archive-list
   (kvalist->values
    (kvhash->alist marmalade/archive-cache))))

(defun marmalade/modtime (filename)
  (let ((modtime 5))
    (elt (file-attributes filename) modtime)))

(defun marmalade-cache-test ()
  "The implementation of the cache test.

Return `t' if the `marmalade/archive-cache-fill' should be
executed on the `marmalade-package-store-dir'."
  (let ((archive (marmalade/archive-file t)))
    (or
     (not (file-exists-p archive))
     (let* ((last-store-change (marmalade/modtime marmalade-package-store-dir))
            (cached-change-time (marmalade/modtime archive)))
       (time-less-p cached-change-time last-store-change)))))

(defun marmalade/archive-load ()
  "Load the cached, lisp version, of the archive.

See `marmalade/archive-file' for how the filename is obtained."
  (setq marmalade/archive-cache
        (catch 'return
          (load-file (marmalade/archive-file t)))))

(defun marmalade/archive-save ()
  "Save the archive to the cached, lisp version.

See `marmalade/archive-file' for how the filename is obtained."
  (let ((archive-lisp (marmalade/archive-file t)))
    (when  (file-writable-p archive-lisp)
      (with-temp-buffer
        (insert
         (format "(throw 'return %S)" marmalade/archive-cache))
        (write-file archive-lisp)))))

(defun marmalade/package-archive (&optional refresh-cache)
  "Make the package archive from package cache.

Re-caches the package cache from the files on disc if the call to
`marmalade-cache-test' returns `t' or if REFRESH-CACHE is t.

Returns a thunk that returns the archive."
  (interactive (list current-prefix-arg))
  ;; Possibly rebuild the cache file
  (when refresh-cache
    (clrhash marmalade/archive-cache)
    (when (and (> (car refresh-cache) 4)
               (file-exists-p (marmalade/archive-file t)))
      (delete-file (marmalade/archive-file t))))
  (let ((cached-archive (marmalade/cache->package-archive)))
    (when (< (length cached-archive) 1)
      (if (not (marmalade-cache-test))
          (marmalade/archive-load)
          ;; Else rebuild the cache
          (marmalade/archive-cache-fill marmalade-package-store-dir)
          (setq cached-archive (marmalade/cache->package-archive))
          (marmalade/archive-save)))
    (if (called-interactively-p 'interactive)
        (message "marmalade archive: %S" cached-archive)
        ;; Return a proc representing the archive
        (lambda (&optional arg)
          (case arg
            (:time
             (marmalade/modtime marmalade-package-store-dir))
            ;; Else return the archive
            (t
             (cons 1 cached-archive)))))))

;; FIXME - should we make this conditional on elnode somehow?
(defun marmalade-archive-handler (httpcon)
  "Send the archive to the HTTP connection."
  ;; We need to get at the cache times here so we can have LM caching
  (let* ((archive (marmalade/package-archive))
         (lm-time (funcall archive :time)))
    ;; Use the if-modified-since function in elnode to do this test
    (elnode-http-header-set
     httpcon "Last-modified" (elnode--rfc1123-date lm-time))
    ;; FIXME - What's the right mimetype here?
    (elnode-http-start httpcon 200 '("Content-type" . "text/plain"))
    (elnode-http-return
     httpcon
     (format "%S" (funcall archive)))))

(provide 'marmalade-archive)

;;; marmalade-archive.el ends here
