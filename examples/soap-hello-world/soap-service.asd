;;;; soap-service.asd -- ASDF system for W3C SOAP 1.2 Email Binding service
;;;;
;;;; W3C SOAP Version 1.2 Email Binding (NOTE, 3 July 2002)
;;;; RFC 3902  -- application/soap+xml media type
;;;; RFC 2045  -- MIME packaging
;;;; RFC 5322  -- internet message format
;;;; RFC 2369/2919 -- mailing list headers

(defsystem "soap-service"
  :description "W3C SOAP 1.2 Email Binding microservice -- batch Maildir processor"
  :author "Dwight Spencer <denzuko@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.1.0"
  :homepage "https://github.com/denzuko/mlisp"
  :depends-on ("xmls")
  :components
  ((:file "src/package")
   (:file "src/rfc5322"   :depends-on ("src/package"))
   (:file "src/soap"      :depends-on ("src/package" "src/rfc5322"))
   (:file "src/maildir"   :depends-on ("src/package"))
   (:file "src/dispatch"  :depends-on ("src/package" "src/soap"))
   (:file "src/reply"     :depends-on ("src/package" "src/soap" "src/rfc5322"))
   (:file "src/main"      :depends-on ("src/package" "src/rfc5322" "src/soap"
                                       "src/maildir" "src/dispatch" "src/reply")))
  :in-order-to ((test-op (test-op "soap-service-test"))))

(defsystem "soap-service-test"
  :description "FiveAM BDD/unit test suite for soap-service"
  :author "Dwight Spencer <denzuko@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.1.0"
  :depends-on ("soap-service" "fiveam")
  :perform (test-op (op system)
    (declare (ignore op))
    (let ((cl-user::*soap-service-test-no-exit* t)
          (root (asdf:system-source-directory system)))
      (declare (special cl-user::*soap-service-test-no-exit*))
      (dolist (f '("test/fiveam/test-soap-service.lisp"))
        (load (merge-pathnames f root))))))
