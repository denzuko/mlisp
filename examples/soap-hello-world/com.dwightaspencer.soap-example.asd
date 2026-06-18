;;;; soap-service.asd -- ASDF system definitions for com.dwightaspencer.soap-example
;;;;
;;;; System hierarchy:
;;;;   com.dwightaspencer.soap-example/soap12-email  -- W3C SOAP 1.2 Email Binding library
;;;;   com.dwightaspencer.soap-example/service       -- calculator microservice example
;;;;   com.dwightaspencer.soap-example/tests         -- FiveAM BDD/regression suite
;;;;   com.dwightaspencer.soap-example/doc           -- 40ants-doc documentation

;;; ── Parent system (required by ASDF for / hierarchy resolution) ──────────
(defsystem "com.dwightaspencer.soap-example"
  :description "W3C SOAP 1.2 Email Binding microservice example"
  :author "Dwight Spencer <denzuko@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.1.0"
  :homepage "https://github.com/denzuko/mlisp"
  :depends-on ("com.dwightaspencer.soap-example/service"))

;;; ── Library: W3C SOAP 1.2 Email Binding transport layer ─────────────────
;;; The generic, publishable layer. No service-specific logic.
;;; Handles: RFC 5322 + MIME (cl-mime), SOAP 1.2 envelope (xmls),
;;;          RFC 2369/2919 list routing, email security header checking,
;;;          Maildir batch processing, W3C spec-compliant reply construction.

(defsystem "com.dwightaspencer.soap-example/soap12-email"
  :description "W3C SOAP 1.2 Email Binding transport -- RFC 5322/MIME/SOAP12/Maildir"
  :author "Dwight Spencer <denzuko@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.1.0"
  :homepage "https://github.com/denzuko/mlisp"
  :depends-on ("cl-mime" "xmls")
  :components
  ((:file "src/package")
   (:file "src/routing"  :depends-on ("src/package"))
   (:file "src/soap"     :depends-on ("src/package"))
   (:file "src/maildir"  :depends-on ("src/package"))
   (:file "src/reply"    :depends-on ("src/package" "src/soap"))))

;;; ── Service: calculator microservice example ─────────────────────────────
;;; Implements the handler protocol on top of the transport layer.
;;; Replace src/dispatch.lisp with your own service to build a new service.

(defsystem "com.dwightaspencer.soap-example/service"
  :description "SOAP 1.2 Email Binding calculator microservice (example)"
  :author "Dwight Spencer <denzuko@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.1.0"
  :depends-on ("com.dwightaspencer.soap-example/soap12-email")
  :components
  ((:file "src/dispatch")
   (:file "src/main"     :depends-on ("src/dispatch")))
  :in-order-to ((test-op (test-op "com.dwightaspencer.soap-example/tests"))))

;;; ── Tests: FiveAM BDD/unit/regression suite ──────────────────────────────

(defsystem "com.dwightaspencer.soap-example/tests"
  :description "FiveAM BDD spec suite for soap-example"
  :author "Dwight Spencer <denzuko@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.1.0"
  :depends-on ("com.dwightaspencer.soap-example/service" "fiveam")
  :perform (test-op (op system)
    (declare (ignore op))
    (let ((cl-user::*soap-service-test-no-exit* t)
          (root (asdf:system-source-directory system)))
      (declare (special cl-user::*soap-service-test-no-exit*))
      (dolist (f '("test/fiveam/test-soap-service.lisp"))
        (load (merge-pathnames f root))))))

;;; ── Documentation: 40ants-doc pages ─────────────────────────────────────
;;; Kept separate so the transport/service systems stay dependency-free
;;; (40ants-doc-full pulls in alexandria, cl-ppcre, etc.).

(defsystem "com.dwightaspencer.soap-example/doc"
  :description "40ants-doc documentation for soap-example"
  :author "Dwight Spencer <denzuko@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.1.0"
  :homepage "https://github.com/denzuko/mlisp"
  :source-control (:git "https://github.com/denzuko/mlisp.git")
  :depends-on ("com.dwightaspencer.soap-example/service" "40ants-doc")
  :components
  ((:file "doc/index")))
