;;;; mlisp-admin.asd — ASDF system definition for mlisp-admin
;;;;
;;;; Build:  sbcl --load build.lisp         (builds both mlisp and mlisp-admin)
;;;;   -or-  (asdf:make :mlisp-admin)       (uncompressed)

(defsystem "mlisp-admin"
  :description "Management CLI for mlisp — list, subscriber, and config administration"
  :author "Dwight Spencer <denzuko@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.2.0"
  :homepage "https://github.com/denzuko/mlisp"

  :build-operation "program-op"
  :build-pathname  "bin/mlisp-admin"
  :entry-point     "mlisp-admin:admin-main"

  :depends-on ("mlisp")

  :components
  ((:module "src"
    :components
    ((:file "admin")))))
