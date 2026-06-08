;;;; mlisp.asd — ASDF system definition for mlisp
;;;;
;;;; Load:   (asdf:load-system :mlisp)
;;;; Or:     (ql:quickload :mlisp)   ; once registered in a dist

(defsystem "mlisp"
  :description "Minimalist mailing list manager — smartlist replacement"
  :long-description
  "mlisp is a compiled, standalone Common Lisp mailing list manager that
   replaces the legacy smartlist suite.  It processes raw RFC 2822 email
   from stdin, maintains an S-expression state database, enforces
   CAN-SPAM/GDPR/CASL compliance on every outbound message, and compiles
   to a native binary via sb-ext:save-lisp-and-die."
  :author "Dwight Spencer <denzuko@dapla.net>"
  :maintainer "Dwight Spencer <denzuko@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.2.0"
  :homepage "https://github.com/denzuko/mlisp"
  :bug-tracker "https://github.com/denzuko/mlisp/issues"
  :source-control (:git "https://github.com/denzuko/mlisp.git")

  ;; Runtime: pure SBCL, no external Quicklisp deps.
  ;; sb-ext is part of SBCL itself; listed explicitly so ASDF
  ;; knows this is SBCL-only.
  :depends-on ()

  :components
  ((:module "src"
    :serial t
    :components
    ((:file "package")
     (:file "state")
     (:file "parser")
     (:file "commands")
     (:file "troff")
     (:file "mta")
     (:file "main"))))

  :in-order-to ((test-op (test-op "mlisp-test"))))
