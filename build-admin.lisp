;;;; build-admin.lisp — Compile mlisp-admin into a compressed native binary
;;;;
;;;; Usage:  sbcl --load build-admin.lisp
;;;; Output: bin/mlisp-admin

(require :asdf)

(let* ((here  (directory-namestring (truename *load-pathname*)))
       (ql-setup (merge-pathnames "quicklisp/setup.lisp"
                                  (user-homedir-pathname))))

  (when (probe-file ql-setup)
    (load ql-setup))

  (pushnew (truename here) asdf:*central-registry* :test #'equal)

  (handler-case
      (progn
        (format t "~&[build] Loading mlisp-admin via ASDF~%")
        (asdf:load-system :mlisp-admin))
    (error (e)
      (format *error-output* "[build] FATAL: ~A~%" e)
      (sb-ext:exit :code 1)))

  (let ((out (merge-pathnames "bin/mlisp-admin" here)))
    (ensure-directories-exist out)
    (format t "~&[build] Compiling to ~A~%" out)
    (funcall (find-symbol "SAVE-LISP-AND-DIE" :sb-ext)
             out
             :toplevel          (find-symbol "ADMIN-MAIN" :mlisp-admin)
             :executable        t
             :compression       t
             :save-runtime-options t)))
