;;;; mlisp-test.asd — ASDF test system for mlisp
;;;;
;;;; Run via:  (asdf:test-system :mlisp)
;;;;   -or-   make test-unit

(defsystem "mlisp-test"
  :description "FiveAM test suite for mlisp (core + MIME)"
  :author "Dwight Spencer <denzuko@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.3.0"
  :depends-on ("mlisp" "fiveam")

  :perform (test-op (op system)
    (declare (ignore op))
    (let* ((root  (asdf:system-source-directory system))
           (sbcl  (or (uiop:getenv "SBCL_PATH")
                      (cl-user::find-program "sbcl"
                                            '("/usr/bin/sbcl"
                                              "/usr/local/bin/sbcl"))
                      "sbcl"))
           (args  (list "--non-interactive")))
      (dolist (file '("test/fiveam/test-mlisp.lisp"
                      "test/fiveam/test-mlisp-mime.lisp"))
        (uiop:run-program
         (append (list sbcl) args
                 (list "--load" (namestring (merge-pathnames file root))))
         :output :interactive :error :interactive)))))
