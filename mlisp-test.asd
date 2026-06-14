;;;; mlisp-test.asd — ASDF test system for mlisp
;;;;
;;;; Primary BDD/unit testing via FiveAM.
;;;; Suites:
;;;;   mlisp-tests::mlisp-suite     (53 specs) — core logic
;;;;   mlisp-mime-tests::mime-suite (25 specs) — MIME processing
;;;;
;;;; Run via:  (asdf:test-system :mlisp)
;;;;   -or-   make test-unit
;;;; In CI:   40ants/run-tests with asdf-system: mlisp
;;;;
;;;; Both test files normally call (sb-ext:exit) after running their
;;;; suite, for standalone `sbcl --load` invocation. When loaded via
;;;; this test-op, CL-USER::*MLISP-TEST-NO-EXIT* is bound to T first,
;;;; so each file signals an ERROR on failure instead of exiting --
;;;; allowing both files to load (and both suites to run, 78 specs
;;;; total) within a single SBCL process.

(defsystem "mlisp-test"
  :description "FiveAM unit/BDD test suite for mlisp (core + MIME)"
  :author "Dwight Spencer <denzuko@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.8.0"
  :depends-on ("mlisp" "fiveam")

  :perform (test-op (op system)
    (declare (ignore op))
    (let ((cl-user::*mlisp-test-no-exit* t)
          (root (asdf:system-source-directory system)))
      (declare (special cl-user::*mlisp-test-no-exit*))
      (dolist (f '("test/fiveam/test-mlisp.lisp"
                   "test/fiveam/test-mlisp-mime.lisp"))
        (load (merge-pathnames f root))))))
