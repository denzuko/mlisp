;;;; test/fiveam/test-mlisp-slsa.lisp — SLSA provenance + net.matrix specs
;;;;
;;;; Verifies:
;;;;   - net.matrix identity strings are defined and non-empty
;;;;   - matrix-label lookup returns correct values
;;;;   - version matches .asd defsystem version (single source of truth)
;;;;   - build output paths are valid pathnames (ENOENT equivalent: probe-file
;;;;     returns nil when absent; a condition means the path is malformed)
;;;;
;;;; Run:
;;;;   qlot exec ros run --load mlisp-test.asd \
;;;;     --eval '(asdf:test-system :mlisp)'
;;;;
;;;; Da Planet Security / denzuko <denzuko@dapla.net>
;;;; BSD 2-Clause License

(defpackage #:mlisp/test-slsa
  (:use #:cl #:fiveam))

(in-package #:mlisp/test-slsa)

(def-suite slsa-suite
  :description "SLSA provenance and net.matrix identity specs")

(in-suite slsa-suite)

;; ── net.matrix identity ───────────────────────────────────────────────────

(test matrix-labels-are-defined
  "mlisp/matrix-id exports *matrix-labels* as a non-empty alist."
  (is (boundp 'mlisp/matrix-id:*matrix-labels*))
  (is (listp mlisp/matrix-id:*matrix-labels*))
  (is (< 0 (length mlisp/matrix-id:*matrix-labels*))))

(test matrix-required-keys-present
  "All seven required net.matrix keys are present in *matrix-labels*."
  (let ((required '("net.matrix.organization"
                    "net.matrix.orgunit"
                    "net.matrix.owner"
                    "net.matrix.oid"
                    "net.matrix.application"
                    "net.matrix.role"
                    "net.matrix.version")))
    (dolist (key required)
      (is (not (null (mlisp/matrix-id:matrix-label key)))
          "Missing net.matrix key: ~a" key))))

(test matrix-values-are-non-empty
  "Every label value is a non-empty string."
  (dolist (pair mlisp/matrix-id:*matrix-labels*)
    (is (stringp (cdr pair))
        "Label value for ~a is not a string" (car pair))
    (is (< 0 (length (cdr pair)))
        "Label value for ~a is empty" (car pair))))

(test matrix-organization-is-daplanet
  "net.matrix.organization is the canonical DPS value."
  (is (string= "daplanet"
               (mlisp/matrix-id:matrix-label "net.matrix.organization"))))

(test matrix-owner-is-dps-identity
  "net.matrix.owner matches the DPS Matrix NOC identity."
  (is (string= "FC13F74B@matrix.net"
               (mlisp/matrix-id:matrix-label "net.matrix.owner"))))

(test matrix-version-matches-asd
  "net.matrix.version matches the .asd defsystem version — single source of truth."
  (let ((asd-ver (asdf:component-version (asdf:find-system :mlisp)))
        (label-ver (mlisp/matrix-id:matrix-label "net.matrix.version")))
    (is (string= asd-ver label-ver)
        "Version mismatch: asd=~a label=~a" asd-ver label-ver)))

;; ── SLSA build output paths ───────────────────────────────────────────────
;;
;; probe-file returns NIL when the file is absent — that is the ENOENT
;; equivalent and is acceptable in unit context (binary not yet built).
;; A condition signalled means the path itself is malformed — that fails.
;; finishes asserts no condition is signalled (FiveAM macro).

(test slsa-binary-output-path-is-deterministic
  "Build output path for mlisp binary is a valid pathname.
   probe-file NIL is acceptable (binary absent in unit context).
   A condition from probe-file means the path is malformed — fail."
  (let ((path #p"bin/mlisp"))
    (is (pathnamep path))
    (is (not (null (pathname-name path))))
    (finishes (probe-file path))))

(test slsa-hash-output-path-is-deterministic
  "Hash output path is a valid pathname."
  (let ((path #p"bin/mlisp.sha256"))
    (is (pathnamep path))
    (is (not (null (pathname-name path))))
    (finishes (probe-file path))))
