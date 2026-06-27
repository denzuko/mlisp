;;;; src/matrix-id.lisp — net.matrix CMDB identity strings
;;;;
;;;; Embedded into every compiled binary at load/compile time via
;;;; defparameter constants. Extractable via strings(1) on the Roswell
;;;; binary for change item attribution and provenance attestation.
;;;;
;;;; DPS-constant values are defined here.
;;;; Version is resolved at compile time from the .asd defsystem via #.
;;;; so there is exactly one source of truth.
;;;;
;;;; IANA PEN: 42387   D&B DUNS: 039-271-257
;;;;
;;;; Da Planet Security / denzuko <denzuko@dapla.net>
;;;; BSD 2-Clause License

(defpackage #:mlisp/matrix-id
  (:use #:cl)
  (:export #:*matrix-labels*
           #:matrix-label))

(in-package #:mlisp/matrix-id)

(defparameter *matrix-labels*
  `(("net.matrix.organization" . "daplanet")
    ("net.matrix.orgunit"      . "dps")
    ("net.matrix.owner"        . "FC13F74B@matrix.net")
    ("net.matrix.oid"          . "iso.org.dod.internet.42387")
    ("net.matrix.duns"         . "iso.org.duns.039271257")
    ("net.matrix.customer"     . "PVT-01")
    ("net.matrix.costcenter"   . "INT-01")
    ("net.matrix.application"  . "mlisp")
    ("net.matrix.role"         . "list-manager")
    ("net.matrix.environment"  . "production")
    ;; Version resolved at compile time from mlisp.asd — single source of truth.
    ("net.matrix.version"      . ,(asdf:component-version
                                   (asdf:find-system :mlisp))))
  "net.matrix CMDB identity labels baked into the binary at compile time.
   Extractable via strings(1) for change item attribution and attestation.")

(defun matrix-label (key)
  "Return the value for the given net.matrix KEY, or NIL if not found."
  (cdr (assoc key *matrix-labels* :test #'string=)))
