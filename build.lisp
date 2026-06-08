;;;; build.lisp — Compile mlisp and mlisp-admin into compressed native binaries
;;;;
;;;; Usage:  sbcl --load build.lisp
;;;; Output: bin/mlisp, bin/mlisp-admin

(let ((here (directory-namestring (truename *load-pathname*))))

  (flet ((load-system (name)
           (pushnew (truename here) asdf:*central-registry* :test #'equal)
           (handler-case
               (progn
                 (format t "~&[build] Loading ~A via ASDF~%" name)
                 (asdf:load-system name))
             (error (e)
               (error "ASDF load of ~A failed: ~A" name e))))

         (build-binary (entry-sym output-rel)
           (let ((out (merge-pathnames output-rel here)))
             (ensure-directories-exist out)
             (format t "~&[build] Compiling to ~A~%" out)
             (funcall (find-symbol "SAVE-LISP-AND-DIE" :sb-ext)
                      out
                      :toplevel          entry-sym
                      :executable        t
                      :compression       t
                      :save-runtime-options t))))

    ;; Build mlisp
    (load-system :mlisp)
    (build-binary (find-symbol "MAIN" :mlisp) "bin/mlisp")

    ;; Re-load image and build mlisp-admin separately
    ;; (save-lisp-and-die exits; run as two separate sbcl invocations via Makefile)
    ))
