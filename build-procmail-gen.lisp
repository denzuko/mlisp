;;;; build-procmail-gen.lisp — Compile mlisp-procmail-gen into a native binary
;;;;
;;;; Usage:  sbcl --load build-procmail-gen.lisp
;;;; Output: bin/mlisp-procmail-gen

(require :asdf)

(let* ((here     (directory-namestring (truename *load-pathname*)))
       (ql-setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file ql-setup) (load ql-setup))

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
        (format t "~&[build] Loading mlisp-procmail-gen via ASDF~%")
        (asdf:load-system :mlisp-procmail-gen))
    (error (e)
      (format *error-output* "[build] FATAL: ASDF load of mlisp-procmail-gen failed: ~A~%" e)
      (sb-ext:exit :code 1)))

  (ensure-directories-exist (merge-pathnames "bin/" here))

  (format t "~&[build] Compiling to ~Abin/mlisp-procmail-gen~%" here)
  (apply #'sb-ext:save-lisp-and-die
   (merge-pathnames "bin/mlisp-procmail-gen" here)
   :toplevel (symbol-function (intern "MAIN" (find-package :mlisp-procmail-gen-main)))
   :executable t
   :save-runtime-options t
   (if (member :sb-core-compression *features*) '(:compression t) '())))
