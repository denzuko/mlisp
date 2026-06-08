;;;; build.lisp — Compile mlisp into a compressed standalone native binary
;;;;
;;;; Usage:  sbcl --load build.lisp
;;;; Output: bin/mlisp

(let* ((here (directory-namestring (truename *load-pathname*)))
       (src  (merge-pathnames "src/mlisp.lisp" here))
       (out  (merge-pathnames "bin/mlisp" here)))

  (ensure-directories-exist out)

  (format t "~&[build] Loading ~A~%" src)
  (load src)

  (format t "~&[build] Compiling to ~A~%" out)

  (funcall
   (find-symbol "SAVE-LISP-AND-DIE" :sb-ext)
   out
   :toplevel   (find-symbol "MAIN" :mlisp)
   :executable t
   :compression t
   :save-runtime-options t))
