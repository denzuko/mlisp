;;;; mlisp-test.asd — ASDF test system for mlisp
;;;;
;;;; Run via: (asdf:test-system :mlisp)
;;;;   -or-   (asdf:load-system :mlisp-test)
;;;;          (fiveam:run! 'mlisp-tests:mlisp-suite)

(defsystem "mlisp-test"
  :description "FiveAM test suite for mlisp"
  :author "Dwight Spencer <denzuko@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.3.0"

  :depends-on ("mlisp" "fiveam")

  :components
  ((:module "test"
    :components
    ((:module "fiveam"
      :components
      ((:file "test-mlisp"))))))

  ;; asdf:test-system :mlisp dispatches here via mlisp.asd :in-order-to
  :perform (test-op (op system)
    (uiop:symbol-call :fiveam :run!
                      (uiop:find-symbol* :mlisp-suite :mlisp-tests))))
