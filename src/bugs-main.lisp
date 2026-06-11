;;;; src/bugs-main.lisp -- mlisp-bugs binary entry point
;;;;
;;;; Usage:
;;;;   mlisp-bugs --mode submit  <package>
;;;;   mlisp-bugs --mode append  <package> <bug-id>
;;;;   mlisp-bugs --mode close   <package> <bug-id>
;;;;   mlisp-bugs --mode control <package>
;;;;   mlisp-bugs --home <dir> --mode submit <package>

(defpackage #:mlisp-bugs-main
  (:use #:cl #:mlisp)
  (:shadow #:main)      ; shadow mlisp:main so our defun creates a fresh symbol
  (:export #:main))

(in-package #:mlisp-bugs-main)

(defun parse-bug-id (str)
  "Extract trailing numeric bug ID from string (e.g. '42' or 'mlisp-bugs-42')."
  (or (parse-integer str :junk-allowed t)
      ;; scan trailing digits
      (let* ((s (string-right-trim " " str))
             (end (length s))
             (start (loop for i from (1- end) downto 0
                          while (digit-char-p (char s i))
                          finally (return (1+ i)))))
        (when (< start end)
          (parse-integer (subseq s start end) :junk-allowed t)))))

(defun main ()
  (let* ((argv      (rest sb-ext:*posix-argv*))
         (home-idx  (position "--home" argv :test #'string=))
         (mode-idx  (position "--mode" argv :test #'string=))
         (home-dir  (when home-idx (nth (1+ home-idx) argv)))
         (mode      (when mode-idx (nth (1+ mode-idx) argv)))
         ;; Remaining positional args after flags
         (pos-args  (remove-if (lambda (a)
                                 (or (string= a "--home")
                                     (string= a "--mode")
                                     (equal a home-dir)
                                     (equal a mode)))
                                argv))
         (pkg-name  (first pos-args))
         (bug-id-s  (second pos-args)))

    (when home-dir
      (setf mlisp:*mlisp-home-override* home-dir))

    (unless pkg-name
      (format *error-output* "mlisp-bugs: package name required~%")
      (sb-ext:exit :code 1))

    (unless mode
      (format *error-output* "mlisp-bugs: --mode required (submit|append|close|control)~%")
      (sb-ext:exit :code 1))

    (mlisp:load-state)

    (unless (mlisp:find-bugs-package pkg-name)
      (format *error-output* "mlisp-bugs: unknown package ~A~%~
                               Register with: mlisp-admin bugs-add-package ~A <submit-addr>~%"
              pkg-name pkg-name)
      (sb-ext:exit :code 1))

    ;; Read stdin
    (multiple-value-bind (headers body-lines _raw)
        (mlisp:read-message-from-stdin)
      (declare (ignore _raw))

      (let ((code
             (cond
               ((string= mode "submit")
                (mlisp:bugs-process-submit pkg-name headers body-lines)
                0)
               ((string= mode "append")
                (let ((bug-id (when bug-id-s (parse-bug-id bug-id-s))))
                  (unless bug-id
                    (format *error-output* "mlisp-bugs: append requires <bug-id>~%")
                    (sb-ext:exit :code 1))
                  (mlisp:bugs-process-append pkg-name bug-id headers body-lines)))
               ((string= mode "close")
                (let ((bug-id (when bug-id-s (parse-bug-id bug-id-s))))
                  (unless bug-id
                    (format *error-output* "mlisp-bugs: close requires <bug-id>~%")
                    (sb-ext:exit :code 1))
                  (mlisp:bugs-process-close pkg-name bug-id headers body-lines)))
               ((string= mode "control")
                (mlisp:bugs-process-control pkg-name headers body-lines))
               (t
                (format *error-output* "mlisp-bugs: unknown mode ~A~%" mode)
                1))))
        (sb-ext:exit :code (or code 0))))))
