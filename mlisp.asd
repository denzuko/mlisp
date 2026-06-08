;;;; mlisp.asd — ASDF system definition for mlisp
;;;;
;;;; Load:    (asdf:load-system :mlisp)
;;;; Test:    (asdf:test-system :mlisp)
;;;; Build:   sbcl --load build.lisp        (uses :compression t)
;;;;   -or-   (asdf:make :mlisp)            (no compression, 45 MB)

(defsystem "mlisp"
  :description "Minimalist mailing list manager — smartlist replacement"
  :long-description
  "mlisp processes raw RFC 2822 email from stdin, maintains an S-expression
   state database, enforces CAN-SPAM/GDPR/CASL compliance on every outbound
   message, and compiles to a native SBCL binary."
  :author "Dwight Spencer <denzuko@dapla.net>"
  :maintainer "Dwight Spencer <denzuko@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.2.0"
  :homepage "https://github.com/denzuko/mlisp"
  :bug-tracker "https://github.com/denzuko/mlisp/issues"
  :source-control (:git "https://github.com/denzuko/mlisp.git")

  ;; program-op wiring: (asdf:make :mlisp) produces an uncompressed binary.
  ;; For the compressed 11 MB production binary use: sbcl --load build.lisp
  :build-operation "program-op"
  :build-pathname  "bin/mlisp"
  :entry-point     "mlisp:main"

  :depends-on ()

  :components
  ((:module "src"
    :serial t
    :components
    ((:file "package")
     (:file "state")
     (:file "mime")
     (:file "parser")
     (:file "commands")
     (:file "troff")
     (:file "mta")
     (:file "metrics")
     (:file "bounce")
     (:file "main"))))

  :in-order-to ((test-op (test-op "mlisp-test"))))
