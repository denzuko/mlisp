;;;; build.lisp — Compile mlisp into a compressed native binary
;;;;
;;;; Usage:  sbcl --load build.lisp
;;;; Output: bin/mlisp

(require :asdf)

(let* ((here  (directory-namestring (truename *load-pathname*)))
       (ql-setup (merge-pathnames "quicklisp/setup.lisp"
                                  (user-homedir-pathname))))

  ;; Load Quicklisp if available
  (when (probe-file ql-setup)
    (load ql-setup))

  (pushnew (truename here) asdf:*central-registry* :test #'equal)

  ;; Treat warnings as warnings, not errors (style warnings are non-fatal)
  (setf asdf:*compile-file-failure-behaviour* :warn)

  (handler-case
      (progn
        (format t "~&[build] Loading mlisp via ASDF~%")
        (asdf:load-system :mlisp))
    (error (e)
      (format *error-output* "[build] FATAL: ASDF load of mlisp failed: ~A~%" e)
      (sb-ext:exit :code 1)))

  (let ((out (merge-pathnames "bin/mlisp" here)))
    (ensure-directories-exist out)
    (format t "~&[build] Compiling to ~A~%" out)
    (funcall (find-symbol "SAVE-LISP-AND-DIE" :sb-ext)
             out
             :toplevel          (find-symbol "MAIN" :mlisp)
             :executable        t
             :compression       t
             :save-runtime-options t)))
