;;;; mlisp-distrib.asd — ASDF system for mlisp-distrib file distribution binary

(defsystem "mlisp-distrib"
  :description "File distribution channel binary for mlisp (-distrib group)"
  :author "Dwight Spencer <denzuko@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.3.0"

  :build-operation "program-op"
  :build-pathname  "bin/mlisp-distrib"
  :entry-point     "mlisp-distrib:distrib-main"

  :depends-on ("mlisp")

  :components
  ((:module "src"
    :components
    ((:file "distrib")))))
