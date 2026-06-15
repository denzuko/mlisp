;;;; mlisp-docs.asd — ASDF system for 40ANTS-DOC documentation generation
;;;;
;;;; Deliberately a SEPARATE system from mlisp.asd (:depends-on ()):
;;;; mlisp is a near-zero-dependency CLI tool (see #99's design
;;;; constraint), and 40ants-doc/locatives/asdf-system pulls in
;;;; alexandria, cl-change-case, cl-ppcre, cl-unicode, closer-mop.
;;;; Loading mlisp itself (to build the 6 binaries) never touches this
;;;; system or its dependencies.
;;;;
;;;; Used by:
;;;;   - CI's "Documentation" job (40ants/build-docs@v1), which guesses
;;;;     a builder by checking external-dependencies for "40ants-doc" --
;;;;     declaring it here (not in mlisp.asd) is what makes the
;;;;     40ANTS-DOC guesser pick mlisp up.
;;;;   - (asdf:load-system :mlisp-docs) for local doc builds.

(defsystem "mlisp-docs"
  :description "40ANTS-DOC documentation pages for mlisp"
  :author "Dwight Spencer <denzuko@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.8.0"
  :homepage "https://github.com/denzuko/mlisp"
  :bug-tracker "https://github.com/denzuko/mlisp/issues"
  :source-control (:git "https://github.com/denzuko/mlisp.git")
  :depends-on ("mlisp" "40ants-doc")
  :components
  ((:file "docs/index")))
