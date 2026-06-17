;;;; test/fiveam/test-soap-service.lisp
;;;;
;;;; FiveAM BDD spec suite for soap-service.
;;;; Written before implementation per project BDD workflow.
;;;;
;;;; Run:
;;;;   (asdf:test-system :soap-service)
;;;;   -or-  ros run --load test/fiveam/test-soap-service.lisp

;;; ── Bootstrap ────────────────────────────────────────────────────────────

(dolist (path (list
               (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))
               #p"/home/claude/quicklisp/setup.lisp"))
  (when (probe-file path) (load path) (return)))

(unless (find-package :fiveam)
  (funcall (find-symbol "QUICKLOAD" :ql) :fiveam :silent t))

;;; Load system under test (no-op if already loaded via asdf:test-system)
(let* ((here (directory-namestring (truename *load-pathname*)))
       (root (namestring (truename (merge-pathnames "../../" (parse-namestring here))))))
  (unless (find-package :soap-service)
    (pushnew (truename root) asdf:*central-registry* :test #'equal)
    (asdf:load-system :soap-service)))

;;; ── Test package ─────────────────────────────────────────────────────────

(defpackage #:soap-service-tests
  (:use #:cl #:fiveam #:soap-service))

(in-package #:soap-service-tests)

(def-suite soap-service-suite
  :description "W3C SOAP 1.2 Email Binding service BDD specs")

(in-suite soap-service-suite)

;;; ── Fixtures ─────────────────────────────────────────────────────────────

(defparameter *soap-ns*  "http://schemas.xmlsoap.org/soap/envelope/")
(defparameter *calc-ns*  "http://example.com/soap/calculator/")

(defun make-soap-email (&key (from "caller@example.com")
                              (to   "soap-calc@example.com")
                              (subject "SOAP Test")
                              (message-id "<test@example.com>")
                              (content-type "application/soap+xml; charset=utf-8")
                              extra-headers
                              body)
  "Build a minimal RFC 5322 / SOAP 1.2 Email Binding message string."
  (with-output-to-string (s)
    (format s "From: ~A~%" from)
    (format s "To: ~A~%"   to)
    (format s "Subject: ~A~%" subject)
    (format s "Message-ID: ~A~%" message-id)
    (format s "Content-Type: ~A~%" content-type)
    (dolist (h extra-headers)
      (format s "~A~%" h))
    (format s "MIME-Version: 1.0~%")
    (format s "~%")
    (when body (write-string body s))))

(defun make-soap-envelope (op &rest params)
  "Build a SOAP 1.2 envelope string for OP with key/value PARAMS."
  (with-output-to-string (s)
    (format s "<?xml version=\"1.0\" encoding=\"utf-8\"?>~%")
    (format s "<env:Envelope xmlns:env=\"~A\"~%" *soap-ns*)
    (format s "              xmlns:cal=\"~A\">~%" *calc-ns*)
    (format s "  <env:Body>~%")
    (format s "    <cal:~A>~%" op)
    (loop for (k v) on params by #'cddr do
      (format s "      <cal:~A>~A</cal:~A>~%" k v k))
    (format s "    </cal:~A>~%" op)
    (format s "  </env:Body>~%")
    (format s "</env:Envelope>~%")))

;;; ── RFC 5322 parser specs ────────────────────────────────────────────────

(test RFC5322-1-parse-headers
  "Headers are parsed into an alist, case-insensitively."
  (multiple-value-bind (headers _body)
      (soap-service:parse-message
       (format nil "From: a@example.com~%To: b@example.com~%~%body~%"))
    (declare (ignore _body))
    (is (string= "a@example.com" (soap-service:header "From" headers)))
    (is (string= "b@example.com" (soap-service:header "To"   headers)))
    (is (string= "a@example.com" (soap-service:header "from" headers)))))

(test RFC5322-2-folded-header
  "Folded headers (RFC 5322 §2.2.3) are unfolded into a single value."
  (multiple-value-bind (headers _)
      (soap-service:parse-message
       (format nil "Subject: hello~% world~%~%"))
    (declare (ignore _))
    (is (search "hello" (soap-service:header "Subject" headers)))
    (is (search "world" (soap-service:header "Subject" headers)))))

(test RFC5322-3-body-after-blank-line
  "Body is everything after the first blank line."
  (multiple-value-bind (_headers body)
      (soap-service:parse-message
       (format nil "From: a@b.com~%~%hello world~%"))
    (declare (ignore _headers))
    (is (search "hello world" body))))

(test RFC5322-4-crlf-and-lf-normalised
  "Both CRLF and bare LF line endings are handled."
  ;; In Common Lisp, use (code-char 13) for CR, not \r (which is letter r).
  (let ((crlf (format nil "~C~%" (code-char 13))))
    (multiple-value-bind (headers-crlf _)
        (soap-service:parse-message
         (concatenate 'string "From: a@b.com" crlf crlf))
      (declare (ignore _))
      (multiple-value-bind (headers-lf __)
          (soap-service:parse-message (format nil "From: a@b.com~%~%"))
        (declare (ignore __))
        (is (string= (soap-service:header "From" headers-crlf)
                     (soap-service:header "From" headers-lf)))))))

;;; ── X-Loop guard specs ───────────────────────────────────────────────────

(test XLOOP-1-own-reply-is-detected
  "A message with X-Loop: matching the service address is detected."
  (multiple-value-bind (headers _)
      (soap-service:parse-message
       (format nil "X-Loop: soap-calc@example.com~%~%"))
    (declare (ignore _))
    (is (soap-service:x-loop-p headers "soap-calc@example.com"))))

(test XLOOP-2-other-loop-not-matched
  "X-Loop: from a different service does not match."
  (multiple-value-bind (headers _)
      (soap-service:parse-message
       (format nil "X-Loop: other-service@example.com~%~%"))
    (declare (ignore _))
    (is (not (soap-service:x-loop-p headers "soap-calc@example.com")))))

(test XLOOP-3-no-loop-header
  "A message with no X-Loop: header is not flagged."
  (multiple-value-bind (headers _)
      (soap-service:parse-message (format nil "From: a@b.com~%~%"))
    (declare (ignore _))
    (is (not (soap-service:x-loop-p headers "soap-calc@example.com")))))

;;; ── Mailing list detection specs (RFC 2369 / RFC 2919) ───────────────────

(test LIST-1-list-id-detected
  "List-Id: header (RFC 2919) triggers list-message detection."
  (multiple-value-bind (headers _)
      (soap-service:parse-message
       (format nil "List-Id: <soap.lists.example.com>~%~%"))
    (declare (ignore _))
    (is (soap-service:list-message-p headers))))

(test LIST-2-list-post-detected
  "List-Post: header (RFC 2369) triggers list-message detection."
  (multiple-value-bind (headers _)
      (soap-service:parse-message
       (format nil "List-Post: <mailto:soap@lists.example.com>~%~%"))
    (declare (ignore _))
    (is (soap-service:list-message-p headers))))

(test LIST-3-precedence-list-detected
  "Precedence: list triggers list-message detection."
  (multiple-value-bind (headers _)
      (soap-service:parse-message
       (format nil "Precedence: list~%~%"))
    (declare (ignore _))
    (is (soap-service:list-message-p headers))))

(test LIST-4-no-list-headers
  "A message with no list headers is not a list message."
  (multiple-value-bind (headers _)
      (soap-service:parse-message
       (format nil "From: a@example.com~%To: soap@example.com~%~%"))
    (declare (ignore _))
    (is (not (soap-service:list-message-p headers)))))

;;; ── Reply address discovery specs ────────────────────────────────────────

(test ROUTE-1-direct-reply-to-from
  "Without list headers, reply goes to the From: address (1:1)."
  (multiple-value-bind (headers _)
      (soap-service:parse-message
       (format nil "From: caller@example.com~%To: soap@example.com~%~%"))
    (declare (ignore _))
    (multiple-value-bind (addr mode)
        (soap-service:reply-to-address headers)
      (is (string= "caller@example.com" addr))
      (is (eq :direct mode)))))

(test ROUTE-2-list-reply-uses-list-post
  "With List-Post: header, reply goes to the list address (1:many)."
  (multiple-value-bind (headers _)
      (soap-service:parse-message
       (format nil "From: member@example.com~%To: soap@lists.example.com~%List-Id: <soap.lists.example.com>~%List-Post: <mailto:soap@lists.example.com>~%~%"))
    (declare (ignore _))
    (multiple-value-bind (addr mode)
        (soap-service:reply-to-address headers)
      (is (string= "soap@lists.example.com" addr))
      (is (eq :list mode)))))

(test ROUTE-3-list-fallback-to-to-when-no-list-post
  "With List-Id: but no List-Post:, falls back to To: address."
  (multiple-value-bind (headers _)
      (soap-service:parse-message
       (format nil "From: member@example.com~%To: soap@lists.example.com~%List-Id: <soap.lists.example.com>~%~%"))
    (declare (ignore _))
    (multiple-value-bind (addr mode)
        (soap-service:reply-to-address headers)
      (is (string= "soap@lists.example.com" addr))
      (is (eq :list mode)))))

;;; ── SOAP envelope specs ──────────────────────────────────────────────────

(test SOAP-1-parse-valid-envelope
  "A well-formed SOAP envelope is parsed without error."
  (let ((envelope (make-soap-envelope "Add" "intA" 3 "intB" 4)))
    (is (not (null (soap-service:parse-soap-envelope envelope))))))

(test SOAP-2-extract-operation
  "The operation element is correctly extracted from the Body."
  (let* ((envelope (make-soap-envelope "Add" "intA" 3 "intB" 4))
         (parsed   (soap-service:parse-soap-envelope envelope)))
    (is (string= "Add" (soap-service:soap-operation-name parsed)))))

(test SOAP-3-extract-params
  "intA and intB are correctly parsed from the operation element."
  (let* ((envelope (make-soap-envelope "Multiply" "intA" 6 "intB" 7))
         (parsed   (soap-service:parse-soap-envelope envelope)))
    (is (= 6 (soap-service:soap-param "intA" parsed)))
    (is (= 7 (soap-service:soap-param "intB" parsed)))))

(test SOAP-4-invalid-envelope-signals-error
  "An invalid SOAP body signals a condition."
  (signals error
    (soap-service:parse-soap-envelope "this is not xml")))

(test SOAP-5-content-type-check
  "application/soap+xml (RFC 3902) is the required Content-Type."
  (is (soap-service:soap-content-type-p
       "application/soap+xml; charset=utf-8"))
  (is (not (soap-service:soap-content-type-p
            "text/plain")))
  (is (not (soap-service:soap-content-type-p
            nil))))

;;; ── Calculator dispatch specs ────────────────────────────────────────────

(test DISPATCH-1-add
  "Add(3, 4) returns 7 with no fault."
  (multiple-value-bind (body fault-p)
      (soap-service:dispatch-soap
       (soap-service:parse-soap-envelope
        (make-soap-envelope "Add" "intA" 3 "intB" 4)))
    (is (not fault-p))
    (is (search "AddResult" body))
    (is (search "7" body))))

(test DISPATCH-2-subtract
  "Subtract(10, 3) returns 7."
  (multiple-value-bind (body fault-p)
      (soap-service:dispatch-soap
       (soap-service:parse-soap-envelope
        (make-soap-envelope "Subtract" "intA" 10 "intB" 3)))
    (is (not fault-p))
    (is (search "SubtractResult" body))
    (is (search "7" body))))

(test DISPATCH-3-multiply
  "Multiply(6, 7) returns 42."
  (multiple-value-bind (body fault-p)
      (soap-service:dispatch-soap
       (soap-service:parse-soap-envelope
        (make-soap-envelope "Multiply" "intA" 6 "intB" 7)))
    (is (not fault-p))
    (is (search "MultiplyResult" body))
    (is (search "42" body))))

(test DISPATCH-4-divide
  "Divide(42, 6) returns 7."
  (multiple-value-bind (body fault-p)
      (soap-service:dispatch-soap
       (soap-service:parse-soap-envelope
        (make-soap-envelope "Divide" "intA" 42 "intB" 6)))
    (is (not fault-p))
    (is (search "DivideResult" body))
    (is (search "7" body))))

(test DISPATCH-5-divide-by-zero-returns-fault
  "Divide(1, 0) returns a soap:Fault."
  (multiple-value-bind (body fault-p)
      (soap-service:dispatch-soap
       (soap-service:parse-soap-envelope
        (make-soap-envelope "Divide" "intA" 1 "intB" 0)))
    (is (eq t fault-p))
    (is (search "Fault" body))
    (is (search "zero" (string-downcase body)))))

(test DISPATCH-6-unknown-operation-returns-fault
  "An unknown operation returns a soap:Fault."
  (multiple-value-bind (body fault-p)
      (soap-service:dispatch-soap
       (soap-service:parse-soap-envelope
        (make-soap-envelope "Sqrt" "intA" 9)))
    (is (eq t fault-p))
    (is (search "Fault" body))))

(test DISPATCH-7-non-integer-param-returns-fault
  "Non-integer parameters return a soap:Fault."
  (multiple-value-bind (body fault-p)
      (soap-service:dispatch-soap
       (soap-service:parse-soap-envelope
        (make-soap-envelope "Add" "intA" "foo" "intB" 4)))
    (is (eq t fault-p))
    (is (search "Fault" body))))

;;; ── Envelope builder specs ───────────────────────────────────────────────

(test BUILD-1-response-has-soap-namespace
  "Built envelope declares the SOAP 1.2 envelope namespace."
  (let ((env (soap-service:build-soap-envelope
              (soap-service:build-result "Add" "AddResult" 7))))
    (is (search "schemas.xmlsoap.org/soap/envelope" env))))

(test BUILD-2-response-has-calc-namespace
  "Built envelope declares the calculator namespace."
  (let ((env (soap-service:build-soap-envelope
              (soap-service:build-result "Add" "AddResult" 7))))
    (is (search "example.com/soap/calculator" env))))

(test BUILD-3-fault-contains-code-and-reason
  "Built fault contains Code and Reason elements."
  (let ((fault (soap-service:build-fault "Sender" "Test reason" "detail")))
    (is (search "Sender" fault))
    (is (search "Test reason" fault))))

(test BUILD-4-result-contains-value
  "Build-result embeds the computed value."
  (let ((result (soap-service:build-result "Multiply" "MultiplyResult" 42)))
    (is (search "42" result))
    (is (search "MultiplyResult" result))))

;;; ── Maildir specs ────────────────────────────────────────────────────────

(test MAILDIR-1-list-new-messages
  "maildir-new returns files from $MAILDIR/new/."
  (let* ((dir   (uiop:temporary-directory))
         (mdir  (merge-pathnames "Maildir/" dir))
         (new   (merge-pathnames "new/" mdir)))
    (ensure-directories-exist new)
    (with-open-file (f (merge-pathnames "test.eml" new)
                       :direction :output :if-does-not-exist :create)
      (write-string (format nil "From: a@b.com~%~%test~%") f))
    (let ((files (soap-service:maildir-new (namestring mdir))))
      (is (= 1 (length files)))
      (uiop:delete-directory-tree mdir :validate t))))

(test MAILDIR-2-mark-read-moves-to-cur
  "mark-read moves a file from new/ to cur/ with :2, flags suffix."
  (let* ((dir   (uiop:temporary-directory))
         (mdir  (merge-pathnames "Maildir/" dir))
         (new   (merge-pathnames "new/" mdir))
         (cur   (merge-pathnames "cur/" mdir)))
    (ensure-directories-exist new)
    (ensure-directories-exist cur)
    (let ((msg (merge-pathnames "test123.eml" new)))
      (with-open-file (f msg :direction :output :if-does-not-exist :create)
        (write-string (format nil "From: a@b.com~%~%test~%") f))
      (soap-service:mark-read msg)
      (is (null (probe-file msg)))
      ;; Maildir spec: :2, flags appended to full filename (including extension)
      (is (probe-file (merge-pathnames "test123.eml:2," cur))))
    (uiop:delete-directory-tree mdir :validate t)))

(test MAILDIR-3-empty-maildir-returns-nil
  "maildir-new returns nil when new/ is empty."
  (let* ((dir  (uiop:temporary-directory))
         (mdir (merge-pathnames "Maildir/" dir))
         (new  (merge-pathnames "new/" mdir)))
    (ensure-directories-exist new)
    (is (null (soap-service:maildir-new (namestring mdir))))
    (uiop:delete-directory-tree mdir :validate t)))

;;; ── Run suite ────────────────────────────────────────────────────────────

(let ((results (run 'soap-service-suite)))
  (explain! results)
  (let ((ok (every #'fiveam::test-passed-p results)))
    (if (and (boundp 'cl-user::*soap-service-test-no-exit*)
             (symbol-value 'cl-user::*soap-service-test-no-exit*))
        (unless ok (error "soap-service-suite: FiveAM tests failed"))
        (sb-ext:exit :code (if ok 0 1)))))
