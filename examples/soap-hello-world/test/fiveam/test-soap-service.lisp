;;;; test/fiveam/test-soap-service.lisp
;;;;
;;;; FiveAM BDD spec suite for soap-service.
;;;; Written before implementation per project BDD workflow.
;;;;
;;;; Run:
;;;;   (asdf:test-system :soap-service)

;;; ── Bootstrap ────────────────────────────────────────────────────────────

(dolist (path (list
               (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))
               #p"/home/claude/quicklisp/setup.lisp"))
  (when (probe-file path) (load path) (return)))

(unless (find-package :fiveam)
  (funcall (find-symbol "QUICKLOAD" :ql) :fiveam :silent t))
(unless (find-package :cl-mime)
  (funcall (find-symbol "QUICKLOAD" :ql) :cl-mime :silent t))

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

(defun make-msg (&key (from "caller@example.com")
                       (to   "soap-calc@example.com")
                       (subject "SOAP Test")
                       (message-id "<test@example.com>")
                       (content-type "application/soap+xml; charset=utf-8")
                       extra-headers
                       body)
  "Build a minimal RFC 5322 / application/soap+xml message string."
  (with-output-to-string (s)
    (format s "From: ~A~%" from)
    (format s "To: ~A~%"   to)
    (format s "Subject: ~A~%" subject)
    (format s "Message-ID: ~A~%" message-id)
    (format s "Content-Type: ~A~%" content-type)
    (format s "MIME-Version: 1.0~%")
    (dolist (h extra-headers)
      (format s "~A~%" h))
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

;;; ── cl-mime integration specs ────────────────────────────────────────────
;;; These verify the cl-mime API we depend on behaves as expected.
;;; soap-service uses mime:parse-headers and mime:parse-mime directly.

(test MIME-1-parse-headers-returns-keyword-alist
  "mime:parse-headers returns alist of (:KEYWORD . value) pairs."
  (let ((hdrs (mime:parse-headers
               (make-string-input-stream
                (format nil "From: a@example.com~%To: b@example.com~%~%")))))
    (is (string= "a@example.com" (cdr (assoc :from hdrs))))
    (is (string= "b@example.com" (cdr (assoc :to   hdrs))))))

(test MIME-2-parse-headers-custom-headers
  "mime:parse-headers includes custom headers (X-Loop, List-Id, etc.)."
  (let ((hdrs (mime:parse-headers
               (make-string-input-stream
                (format nil "X-Loop: soap-calc@example.com~%List-Id: <soap.lists.example.com>~%~%")))))
    (is (string= "soap-calc@example.com"   (cdr (assoc :x-loop  hdrs))))
    (is (string= "<soap.lists.example.com>" (cdr (assoc :list-id hdrs))))))

(test MIME-3-parse-mime-extracts-content-type-and-body
  "mime:parse-mime returns object with content-type/subtype and decoded body."
  (let* ((msg    (make-msg :body "<env/>"))
         (parsed (mime:parse-mime msg)))
    (is (string= "application" (mime:content-type    parsed)))
    (is (string= "soap+xml"    (mime:content-subtype parsed)))
    (is (search  "<env/>"      (mime:content         parsed)))))

;;; ── X-Loop guard specs ───────────────────────────────────────────────────

(test XLOOP-1-own-reply-is-detected
  "x-loop-p returns T when X-Loop: matches service address."
  (let ((hdrs (mime:parse-headers
               (make-string-input-stream
                (format nil "X-Loop: soap-calc@example.com~%~%")))))
    (is (soap-service:x-loop-p hdrs "soap-calc@example.com"))))

(test XLOOP-2-other-loop-not-matched
  "x-loop-p returns NIL when X-Loop: is a different service."
  (let ((hdrs (mime:parse-headers
               (make-string-input-stream
                (format nil "X-Loop: other@example.com~%~%")))))
    (is (not (soap-service:x-loop-p hdrs "soap-calc@example.com")))))

(test XLOOP-3-no-loop-header
  "x-loop-p returns NIL when X-Loop: is absent."
  (let ((hdrs (mime:parse-headers
               (make-string-input-stream
                (format nil "From: a@b.com~%~%")))))
    (is (not (soap-service:x-loop-p hdrs "soap-calc@example.com")))))

;;; ── Mailing list detection specs (RFC 2369 / RFC 2919) ───────────────────

(test LIST-1-list-id-detected
  "List-Id: (RFC 2919) triggers list-message detection."
  (let ((hdrs (mime:parse-headers
               (make-string-input-stream
                (format nil "List-Id: <soap.lists.example.com>~%~%")))))
    (is (soap-service:list-message-p hdrs))))

(test LIST-2-list-post-detected
  "List-Post: (RFC 2369) triggers list-message detection."
  (let ((hdrs (mime:parse-headers
               (make-string-input-stream
                (format nil "List-Post: <mailto:soap@lists.example.com>~%~%")))))
    (is (soap-service:list-message-p hdrs))))

(test LIST-3-precedence-list-detected
  "Precedence: list triggers list-message detection."
  (let ((hdrs (mime:parse-headers
               (make-string-input-stream
                (format nil "Precedence: list~%~%")))))
    (is (soap-service:list-message-p hdrs))))

(test LIST-4-no-list-headers
  "A message with no list headers is not a list message."
  (let ((hdrs (mime:parse-headers
               (make-string-input-stream
                (format nil "From: a@example.com~%To: b@example.com~%~%")))))
    (is (not (soap-service:list-message-p hdrs)))))

;;; ── Reply address discovery specs ────────────────────────────────────────

(test ROUTE-1-direct-reply-to-from
  "Without list headers, reply goes to From: (1:1)."
  (let ((hdrs (mime:parse-headers
               (make-string-input-stream
                (format nil "From: caller@example.com~%To: soap@example.com~%~%")))))
    (multiple-value-bind (addr mode)
        (soap-service:reply-to-address hdrs)
      (is (string= "caller@example.com" addr))
      (is (eq :direct mode)))))

(test ROUTE-2-list-reply-uses-list-post
  "With List-Post:, reply goes to the list address (1:many)."
  (let ((hdrs (mime:parse-headers
               (make-string-input-stream
                (format nil "From: member@example.com~%To: soap@lists.example.com~%List-Id: <soap.lists.example.com>~%List-Post: <mailto:soap@lists.example.com>~%~%")))))
    (multiple-value-bind (addr mode)
        (soap-service:reply-to-address hdrs)
      (is (string= "soap@lists.example.com" addr))
      (is (eq :list mode)))))

(test ROUTE-3-list-fallback-to-to-when-no-list-post
  "With List-Id: but no List-Post:, falls back to To: address."
  (let ((hdrs (mime:parse-headers
               (make-string-input-stream
                (format nil "From: member@example.com~%To: soap@lists.example.com~%List-Id: <soap.lists.example.com>~%~%")))))
    (multiple-value-bind (addr mode)
        (soap-service:reply-to-address hdrs)
      (is (string= "soap@lists.example.com" addr))
      (is (eq :list mode)))))

;;; ── SOAP content-type spec ───────────────────────────────────────────────

(test SOAP-CT-1-soap-xml-accepted
  "application/soap+xml (RFC 3902) is the required Content-Type."
  (is (soap-service:soap-content-type-p "application" "soap+xml"))
  (is (not (soap-service:soap-content-type-p "text" "plain")))
  (is (not (soap-service:soap-content-type-p nil nil))))

;;; ── SOAP envelope specs ──────────────────────────────────────────────────

(test SOAP-1-parse-valid-envelope
  "A well-formed SOAP envelope is parsed without error."
  (is (not (null (soap-service:parse-soap-envelope
                  (make-soap-envelope "Add" "intA" 3 "intB" 4))))))

(test SOAP-2-extract-operation-name
  "The operation element's local name is correctly extracted."
  (let ((op (soap-service:parse-soap-envelope
             (make-soap-envelope "Add" "intA" 3 "intB" 4))))
    (is (string= "Add" (soap-service:soap-operation-name op)))))

(test SOAP-3-extract-integer-params
  "intA and intB are correctly extracted as integers."
  (let ((op (soap-service:parse-soap-envelope
             (make-soap-envelope "Multiply" "intA" 6 "intB" 7))))
    (is (= 6 (soap-service:soap-param "intA" op)))
    (is (= 7 (soap-service:soap-param "intB" op)))))

(test SOAP-4-invalid-xml-signals-error
  "Non-XML body signals a condition."
  (signals error
    (soap-service:parse-soap-envelope "this is not xml")))

;;; ── Calculator dispatch specs ────────────────────────────────────────────

(test DISPATCH-1-add
  "Add(3, 4) = 7, no fault."
  (multiple-value-bind (body fault-p)
      (soap-service:dispatch-soap
       (soap-service:parse-soap-envelope
        (make-soap-envelope "Add" "intA" 3 "intB" 4)))
    (is (not fault-p))
    (is (search "AddResult" body))
    (is (search "7" body))))

(test DISPATCH-2-subtract
  "Subtract(10, 3) = 7."
  (multiple-value-bind (body fault-p)
      (soap-service:dispatch-soap
       (soap-service:parse-soap-envelope
        (make-soap-envelope "Subtract" "intA" 10 "intB" 3)))
    (is (not fault-p))
    (is (search "SubtractResult" body))
    (is (search "7" body))))

(test DISPATCH-3-multiply
  "Multiply(6, 7) = 42."
  (multiple-value-bind (body fault-p)
      (soap-service:dispatch-soap
       (soap-service:parse-soap-envelope
        (make-soap-envelope "Multiply" "intA" 6 "intB" 7)))
    (is (not fault-p))
    (is (search "MultiplyResult" body))
    (is (search "42" body))))

(test DISPATCH-4-divide
  "Divide(42, 6) = 7."
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

(test BUILD-1-envelope-has-soap-namespace
  "Built envelope declares the SOAP 1.2 envelope namespace."
  (let ((env (soap-service:build-soap-envelope
              (soap-service:build-result "Add" "AddResult" 7))))
    (is (search "schemas.xmlsoap.org/soap/envelope" env))))

(test BUILD-2-envelope-has-calc-namespace
  "Built envelope declares the calculator namespace."
  (let ((env (soap-service:build-soap-envelope
              (soap-service:build-result "Add" "AddResult" 7))))
    (is (search "example.com/soap/calculator" env))))

(test BUILD-3-fault-contains-code-and-reason
  "Built fault contains Code/Reason elements."
  (let ((fault (soap-service:build-fault "Sender" "Test reason" "detail")))
    (is (search "Sender"      fault))
    (is (search "Test reason" fault))))

(test BUILD-4-result-contains-value
  "build-result embeds the computed value."
  (let ((result (soap-service:build-result "Multiply" "MultiplyResult" 42)))
    (is (search "42"            result))
    (is (search "MultiplyResult" result))))

;;; ── Maildir specs ────────────────────────────────────────────────────────

(test MAILDIR-1-list-new-messages
  "maildir-new returns files from $MAILDIR/new/."
  (let* ((mdir (merge-pathnames "Maildir/" (uiop:temporary-directory)))
         (new  (merge-pathnames "new/" mdir)))
    (ensure-directories-exist new)
    (with-open-file (f (merge-pathnames "test.eml" new)
                       :direction :output :if-does-not-exist :create)
      (write-string "From: a@b.com\n\ntest\n" f))
    (let ((files (soap-service:maildir-new (namestring mdir))))
      (is (= 1 (length files))))
    (uiop:delete-directory-tree mdir :validate t)))

(test MAILDIR-2-mark-read-moves-to-cur
  "mark-read moves new/msg -> cur/msg:2, (Maildir convention)."
  (let* ((mdir (merge-pathnames "Maildir/" (uiop:temporary-directory)))
         (new  (merge-pathnames "new/" mdir))
         (cur  (merge-pathnames "cur/" mdir)))
    (ensure-directories-exist new)
    (ensure-directories-exist cur)
    (let ((msg (merge-pathnames "test123.eml" new)))
      (with-open-file (f msg :direction :output :if-does-not-exist :create)
        (write-string "From: a@b.com\n\ntest\n" f))
      (soap-service:mark-read msg)
      (is (null (probe-file msg)))
      (is (probe-file (merge-pathnames "test123.eml:2," cur))))
    (uiop:delete-directory-tree mdir :validate t)))

(test MAILDIR-3-empty-maildir-returns-nil
  "maildir-new returns nil when new/ is empty."
  (let* ((mdir (merge-pathnames "Maildir/" (uiop:temporary-directory)))
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
