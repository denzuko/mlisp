;;;; src/maildir.lisp -- Maildir batch message reader
;;;;
;;;; maildir-new  -- list files in $MAILDIR/new/
;;;; mark-read    -- move new/ -> cur/ with :2, flags (Maildir spec)
;;;; slurp-file   -- read entire file as string

(in-package #:soap-service)

(defun ensure-trailing-slash (str)
  (if (and (> (length str) 0)
           (char= (char str (1- (length str))) #\/))
      str
      (concatenate 'string str "/")))

(defun maildir-new (maildir)
  "Return list of pathnames of all files in MAILDIR/new/.
   Returns nil if the directory is empty or does not exist."
  (let* ((new-str (concatenate 'string (ensure-trailing-slash maildir) "new/"))
         (new-pn  (pathname new-str)))
    (when (probe-file new-pn)
      (directory
       (make-pathname :directory (pathname-directory new-pn)
                      :name :wild
                      :type :wild)))))

(defun mark-read (pathname)
  "Move PATHNAME from Maildir new/ to cur/, appending ':2,' flags suffix
   as required by the Maildir specification.
   Strips any existing info field (colon-separated suffix) before adding."
  (let* ((filename (file-namestring pathname))
         ;; Strip existing info field if present
         (base     (let ((colon (position #\: filename)))
                     (if colon (subseq filename 0 colon) filename)))
         (cur-dir  (make-pathname
                    :directory (append (butlast (pathname-directory pathname))
                                       (list "cur"))))
         (cur-path (merge-pathnames
                    (format nil "~A:2," base) cur-dir)))
    (ensure-directories-exist cur-dir)
    (rename-file pathname cur-path)))

(defun slurp-file (pathname)
  "Read entire file as a UTF-8 string."
  (with-open-file (s pathname :external-format :utf-8)
    (let ((buf (make-string (file-length s))))
      (read-sequence buf s)
      buf)))
