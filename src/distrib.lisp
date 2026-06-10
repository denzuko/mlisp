;;;; src/distrib.lisp — File distribution engine for mlisp-distrib
;;;;
;;;; Distributes files as MIME attachments to -distrib list subscribers.
;;;; Suitable for binary release channels and filebone-style distribution.

(defpackage #:mlisp-distrib
  (:use #:cl #:mlisp)
  (:export #:distrib-main))

(in-package #:mlisp-distrib)

;;; Forward declarations
(declaim (special mlisp:*mlisp-home-override*))
(declaim (ftype (function (t t) t) mlisp:audit-append mlisp:find-list))

(defun file-mime-type (filename)
  "Return a MIME type string based on file extension."
  (let* ((name  (string-downcase filename))
         (dot   (position #\. name :from-end t))
         (ext   (if dot (subseq name (1+ dot)) "")))
    (cond
      ((member ext '("gz" "tgz" "bz2" "xz" "zip" "tar") :test #'string=)
       "application/octet-stream")
      ((string= ext "txt") "text/plain")
      ((string= ext "asc") "application/pgp-signature")
      (t "application/octet-stream"))))

(defun base64-encode-file (path)
  "Return base64-encoded content of file at PATH, split into 76-char lines."
  (let* ((bytes (with-open-file (s path :element-type '(unsigned-byte 8))
                  (let ((buf (make-array (file-length s)
                                         :element-type '(unsigned-byte 8))))
                    (read-sequence buf s)
                    buf)))
         (chars "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"))
    (with-output-to-string (out)
      (let ((col 0))
        (loop for i from 0 below (length bytes) by 3 do
          (let* ((b0 (aref bytes i))
                 (b1 (if (< (1+ i) (length bytes)) (aref bytes (1+ i)) 0))
                 (b2 (if (< (+ i 2) (length bytes)) (aref bytes (+ i 2)) 0))
                 (n  (logior (ash b0 16) (ash b1 8) b2))
                 (c0 (char chars (ash n -18)))
                 (c1 (char chars (logand (ash n -12) #x3f)))
                 (c2 (if (< (1+ i) (length bytes))
                         (char chars (logand (ash n -6) #x3f))
                         #\=))
                 (c3 (if (< (+ i 2) (length bytes))
                         (char chars (logand n #x3f))
                         #\=)))
            (dolist (c (list c0 c1 c2 c3))
              (write-char c out)
              (incf col)
              (when (= col 76)
                (terpri out)
                (setf col 0)))))
        (when (> col 0) (terpri out))))))

(defun distrib-file (list-id file-path)
  "Send FILE-PATH to all subscribers of the distrib list LIST-ID."
  (let* ((lst      (mlisp:find-list list-id))
         (max-kb   (or (getf lst :max-file-size-kb) 512))
         (fname    (file-namestring file-path))
         (fsize    (ignore-errors (with-open-file (s file-path) (file-length s)))))
    ;; File size check
    (when (and fsize (> fsize (* max-kb 1024)))
      (format *error-output*
              "mlisp-distrib: ~A exceeds max-file-size-kb (~A)~%"
              fname max-kb)
      (return-from distrib-file 1))
    (unless (probe-file file-path)
      (format *error-output* "mlisp-distrib: file not found: ~A~%" file-path)
      (return-from distrib-file 1))
    (let* ((drop     (mlisp:list-drop-address list-id))
           (req      (mlisp:list-request-address list-id))
           (mime-t   (file-mime-type fname))
           (b64      (base64-encode-file file-path))
           (boundary "mlisp-distrib-boundary-0001")
           (subj     (format nil "[~A] ~A" list-id fname))
           (body
            (format nil
                    "--~A~%Content-Type: text/plain~%~%~
New file available: ~A~%~
List: ~A~%~
To request the index, send: get index~%~
--~A~%~
Content-Type: ~A~%~
Content-Transfer-Encoding: base64~%~
Content-Disposition: attachment; filename=~S~%~%~
~A~%--~A--~%"
                    boundary fname list-id
                    boundary mime-t fname b64 boundary))
           (extra-hdrs
            (append
             (mlisp:rfc2369-headers list-id)
             (list (cons "Subject"      subj)
                   (cons "Sender"       drop)
                   (cons "Reply-To"     req)
                   (cons "To"           drop)
                   (cons "MIME-Version" "1.0")
                   (cons "Content-Type"
                         (format nil "multipart/mixed; boundary=~S" boundary))
                   (cons (mlisp:list-loop-header list-id) "1"))))
           (addrs    (mlisp:subscriber-addresses list-id)))
      (dolist (addr addrs)
        (mlisp:sendmail (list addr) body :extra-headers extra-hdrs))
      (mlisp:audit-append
       (list :event :distrib-sent :list list-id :file fname))
      (format t "Distributed ~A to ~A subscriber(s) on ~A~%"
              fname (length addrs) list-id)
      0)))

(defun distrib-index (list-id)
  "Send the file index for LIST-ID to all subscribers."
  (let* ((lst   (mlisp:find-list list-id))
         (ddir  (getf lst :distrib-path))
         (drop  (mlisp:list-drop-address list-id))
         (addrs (mlisp:subscriber-addresses list-id)))
    (unless ddir
      (format *error-output* "mlisp-distrib: no distrib-path configured for ~A~%" list-id)
      (return-from distrib-index 1))
    (let* ((files (if (probe-file ddir)
                      (uiop:directory-files
                       (uiop:ensure-directory-pathname ddir))
                      '()))
           (body
            (with-output-to-string (s)
              (format s "[~A] Available files:~%~%" list-id)
              (if files
                  (dolist (f files)
                    (format s "  ~A  (~A bytes)~%"
                            (file-namestring f)
                            (ignore-errors
                              (with-open-file (fs f :element-type '(unsigned-byte 8))
                                (file-length fs)))))
                  (format s "  (no files available)~%"))
              (format s "~%To receive a file, send email to ~A~%~
with subject: get <filename>~%" drop)))
           (extra-hdrs
            (append
             (mlisp:rfc2369-headers list-id)
             (list (cons "Subject" (format nil "[~A] File index" list-id))
                   (cons "Sender" drop)
                   (cons "To"     drop)
                   (cons (mlisp:list-loop-header list-id) "1")))))
      (dolist (addr addrs)
        (mlisp:sendmail (list addr) body :extra-headers extra-hdrs))
      (format t "Sent index (~A file~:P) to ~A subscriber~:P on ~A~%"
              (length files) (length addrs) list-id)
      0)))

(defun distrib-get (list-id filename requestor)
  "Send a specific file to REQUESTOR from the LIST-ID distrib spool."
  (let* ((lst  (mlisp:find-list list-id))
         (ddir (getf lst :distrib-path)))
    (unless ddir
      (format *error-output* "mlisp-distrib: no distrib-path for ~A~%" list-id)
      (return-from distrib-get 1))
    (let ((path (merge-pathnames filename (uiop:ensure-directory-pathname ddir))))
      (unless (probe-file path)
        (format *error-output* "mlisp-distrib: file not found: ~A~%" filename)
        (return-from distrib-get 1))
      (let ((extra-hdrs
             (append
              (mlisp:rfc2369-headers list-id)
              (list (cons "Subject"  (format nil "[~A] ~A" list-id filename))
                    (cons "To"       requestor)
                    (cons "Sender"   (mlisp:list-drop-address list-id))
                    (cons (mlisp:list-loop-header list-id) "1"))))
            (body (format nil "File: ~A~%~%~A" filename
                          (ignore-errors (base64-encode-file path)))))
        (mlisp:sendmail (list requestor) body :extra-headers extra-hdrs)
        (format t "Sent ~A to ~A~%" filename requestor)
        0))))

(defun distrib-main ()
  "Entry point for mlisp-distrib binary.
   Usage: mlisp-distrib [--home <dir>] <list-id> <file>
          mlisp-distrib [--home <dir>] <list-id> --index"
  (let ((args (cdr sb-ext:*posix-argv*)))
    (when (or (null args) (member "--help" args :test #'string=))
      (format t
"Usage: mlisp-distrib [--home <dir>] <list-id> <file>
       mlisp-distrib [--home <dir>] <list-id> --index

Distribute a file or send the file index to all subscribers.

  <file>    Distribute file as MIME attachment to all subscribers
  --index   Send current file index to all subscribers

The list must be of type :distrib (mlisp-admin add-distrib).
")
      (sb-ext:exit :code (if (null args) 1 0)))

    (multiple-value-bind (home-dir _mode remaining)
        (mlisp::parse-common-flags args)
      (declare (ignore _mode))
      (when home-dir (setf mlisp:*mlisp-home-override* home-dir))

      (when (null remaining)
        (format *error-output* "mlisp-distrib: error: list-id required~%")
        (sb-ext:exit :code 1))

      (let ((list-id (string-downcase (first remaining)))
            (arg2    (second remaining)))
        (handler-case
            (progn
              (mlisp:load-state)
              (sb-ext:exit
               :code (cond
                 ;; mlisp-distrib <list-id> --index
                 ((or (null arg2) (string= arg2 "--index"))
                  (distrib-index list-id))
                 ;; mlisp-distrib <list-id> <file>
                 (t
                  (distrib-file list-id arg2)))))
          (error (e)
            (format *error-output* "mlisp-distrib: fatal: ~A~%" e)
            (sb-ext:exit :code 2)))))))
