;;;; build-distrib.lisp — Compile mlisp-distrib into a compressed native binary
;;;;
;;;; Usage:  sbcl --load build-distrib.lisp
;;;; Output: bin/mlisp-distrib

(require :asdf)

(let* ((here  (directory-namestring (truename *load-pathname*)))
       (ql-setup (merge-pathnames "quicklisp/setup.lisp"
                                  (user-homedir-pathname))))

  (when (probe-file ql-setup)
    (load ql-setup))

  (pushnew (truename here) asdf:*central-registry* :test #'equal)

  (handler-case
      (progn
        (format t "~&[build] Loading mlisp-distrib via ASDF~%")
        (asdf:load-system :mlisp-distrib))
    (error (e)
      (format *error-output* "[build] FATAL: ~A~%" e)
      (sb-ext:exit :code 1)))

  (let ((out (merge-pathnames "bin/mlisp-distrib" here)))
    (ensure-directories-exist out)
    (format t "~&[build] Compiling to ~A~%" out)
    (funcall (find-symbol "SAVE-LISP-AND-DIE" :sb-ext)
             out
             :toplevel          (find-symbol "DISTRIB-MAIN" :mlisp-distrib)
             :executable        t
             :compression       t
             :save-runtime-options t)))
