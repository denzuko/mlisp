;;;; mlisp-procmail-gen.asd -- mlisp-procmail-gen binary entry point

(asdf:defsystem #:mlisp-procmail-gen
  :description "s-expr DSL compiler for procmailrc recipes"
  :author "Dwight Spencer <dwight@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.1.0"
  :depends-on (#:mlisp)
  :serial t
  :components
  ((:file "src/procmail-gen-main")))
