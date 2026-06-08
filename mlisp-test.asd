;;;; mlisp-test.asd — ASDF test system for mlisp
;;;;
;;;; Run via:  (asdf:test-system :mlisp)
;;;;   -or-   make test-unit
;;;;   -or-   sbcl --load test/fiveam/test-mlisp.lisp
;;;;          sbcl --load test/fiveam/test-mlisp-mime.lisp

(defsystem "mlisp-test"
  :description "FiveAM test suite for mlisp (core + MIME)"
  :author "Dwight Spencer <denzuko@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.3.0"

  :depends-on ("mlisp" "fiveam")

  ;; The test files are self-contained standalone scripts with their own
  ;; package definitions and load logic. Run them via :perform, not :components.
  :perform (test-op (op system)
    (declare (ignore op system))
    (format t "~&==> Running mlisp FiveAM tests~%")
    (uiop:run-program
     (list (uiop:find-exe "sbcl")
           "--non-interactive"
           "--eval" (format nil "(load ~S)" (uiop:find-symbol* :ql-setup :ql))
           "--load" (namestring
                     (asdf:system-relative-pathname :mlisp
                                                    "test/fiveam/test-mlisp.lisp")))
     :output :interactive :error :interactive)
    (uiop:run-program
     (list (uiop:find-exe "sbcl")
           "--non-interactive"
           "--load" (namestring
                     (asdf:system-relative-pathname :mlisp
                                                    "test/fiveam/test-mlisp-mime.lisp")))
     :output :interactive :error :interactive)))
