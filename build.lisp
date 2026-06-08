;;;; build.lisp — Compile mlisp into a compressed standalone native binary
;;;;
;;;; Usage:  sbcl --load build.lisp
;;;; Output: bin/mlisp
;;;;
;;;; Loads via ASDF when available; falls back to direct component load.

(let* ((here (directory-namestring (truename *load-pathname*)))
       (out  (merge-pathnames "bin/mlisp" here)))

  (ensure-directories-exist out)

  ;; Prefer ASDF load
  (pushnew (truename here) asdf:*central-registry* :test #'equal)
  (handler-case
      (progn
        (format t "~&[build] Loading via ASDF~%")
        (asdf:load-system :mlisp))
    (error (e)
      (format t "~&[build] ASDF unavailable (~A), loading directly~%" e)
      (dolist (f '("src/package.lisp" "src/state.lisp" "src/parser.lisp"
                   "src/commands.lisp" "src/troff.lisp" "src/mta.lisp"
                   "src/main.lisp"))
        (load (merge-pathnames f here)))))

  (format t "~&[build] Compiling to ~A~%" out)

  (funcall
   (find-symbol "SAVE-LISP-AND-DIE" :sb-ext)
   out
   :toplevel          (find-symbol "MAIN" :mlisp)
   :executable        t
   :compression       t
   :save-runtime-options t))
