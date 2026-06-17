;;;; examples/soap-hello-world/build.lisp
;;;;
;;;; Compile soap-service.lisp into a standalone SBCL binary.
;;;;
;;;; Usage:
;;;;   sbcl --noinform --load build.lisp
;;;;
;;;; Output: ./soap-service (executable, ~50MB with SBCL runtime)

;; Load Quicklisp from the standard locations.
(dolist (path (list
               (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))
               #p"/home/claude/quicklisp/setup.lisp"
               #p"/root/quicklisp/setup.lisp"))
  (when (probe-file path)
    (load path)
    (return)))

(funcall (find-symbol "QUICKLOAD" (find-package "QL")) :xmls :silent t)

;; Sentinel: prevents soap-service.lisp's (main) guard from firing
;; when the file is loaded during this build step.
(defvar *soap-service-building* t)

;; Load the service source (defines package, types, functions).
(load (merge-pathnames "soap-service.lisp" *load-pathname*))

;; Dump a standalone binary with main as the entry point.
(sb-ext:save-lisp-and-die
  "soap-service"
  :toplevel #'soap-service::main
  :executable t
  :purify t)
