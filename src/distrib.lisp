;;;; src/distrib.lisp — File distribution engine for mlisp-distrib
;;;;
;;;; Distributes files as MIME attachments to -distrib list subscribers.
;;;; Suitable for binary release channels and filebone-style distribution.

(defpackage #:mlisp-distrib
  (:use #:cl #:mlisp)
  (:export #:distrib-main))

(in-package #:mlisp-distrib)

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

(defun distrib-main ()
  "Entry point for mlisp-distrib binary.
   Usage: mlisp-distrib [--home <dir>] <list-id> <file>"
  (let ((args (cdr sb-ext:*posix-argv*)))
    (when (or (null args) (member "--help" args :test #'string=))
      (format t "Usage: mlisp-distrib [--home <dir>] <list-id> <file>~%~
~%~
Distributes <file> as a MIME attachment to all subscribers of <list-id>.~%~
~%~
The list must be of type :distrib (created with mlisp-admin add-distrib).~%")
      (sb-ext:exit :code (if (null args) 1 0)))

    (multiple-value-bind (home-dir _mode remaining)
        (mlisp::parse-common-flags args)
      (declare (ignore _mode))
      (when home-dir (setf mlisp:*mlisp-home-override* home-dir))

      (when (< (length remaining) 2)
        (format *error-output* "mlisp-distrib: error: list-id and file required~%")
        (sb-ext:exit :code 1))

      (let ((list-id   (string-downcase (first remaining)))
            (file-path (second remaining)))
        (handler-case
            (progn
              (mlisp:load-state)
              (sb-ext:exit :code (distrib-file list-id file-path)))
          (error (e)
            (format *error-output* "mlisp-distrib: fatal: ~A~%" e)
            (sb-ext:exit :code 2)))))))
