;;;; mlisp-bugs.asd -- mlisp-bugs binary entry point

(asdf:defsystem #:mlisp-bugs
  :description "Debbugs-compatible email bug tracker for mlisp"
  :author "Dwight Spencer <dwight@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.7.0"
  :depends-on (#:mlisp)
  :serial t
  :components
  ((:file "src/bugs-main")))
