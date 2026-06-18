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
  ;; Force recompilation by deleting the ASDF output cache for this project.
  ;; asdf:clear-output-translations resets path mappings but leaves compiled
  ;; fasls in place; explicit deletion ensures source changes always take effect.
  (let ((cache (merge-pathnames
                (make-pathname :directory
                               (list :relative (format nil "~A-~A-~A"
                                                       (lisp-implementation-type)
                                                       (lisp-implementation-version)
                                                       (machine-type))))
                (uiop:xdg-cache-home "common-lisp/"))))
    (when (probe-file cache)
      (uiop:delete-directory-tree cache :validate t :if-does-not-exist :ignore)))

  (setf asdf:*compile-file-failure-behaviour* :warn)

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
    (apply #'funcall (find-symbol "SAVE-LISP-AND-DIE" :sb-ext)
             out
             :toplevel          (find-symbol "DISTRIB-MAIN" :mlisp-distrib)
             :executable        t
             :save-runtime-options t
             (if (member :sb-core-compression *features*) '(:compression t) '()))))
