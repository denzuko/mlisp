;;;; build-distrib.lisp — Compile mlisp-distrib into a compressed native binary

(let ((here (directory-namestring (truename *load-pathname*))))
  (pushnew (truename here) asdf:*central-registry* :test #'equal)
  (handler-case
      (progn
        (format t "~&[build] Loading mlisp-distrib via ASDF~%")
        (asdf:load-system :mlisp-distrib))
    (error (e)
      (error "ASDF load of mlisp-distrib failed: ~A" e)))
  (let ((out (merge-pathnames "bin/mlisp-distrib" here)))
    (ensure-directories-exist out)
    (format t "~&[build] Compiling to ~A~%" out)
    (funcall (find-symbol "SAVE-LISP-AND-DIE" :sb-ext)
             out
             :toplevel          (find-symbol "DISTRIB-MAIN" :mlisp-distrib)
             :executable        t
             :compression       t
             :save-runtime-options t)))
