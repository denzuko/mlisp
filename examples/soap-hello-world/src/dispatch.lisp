;;;; src/dispatch.lisp -- calculator SOAP operation dispatcher (example service)
;;;;
;;;; This is the EXAMPLE/USER CODE layer -- domain-specific, not part of
;;;; the generic email-SOAP transport. A real service would replace this
;;;; file with its own handler implementing the same interface:
;;;;
;;;;   (lambda (operation) ...)
;;;;     operation -- xmls node (first child of soap:Body)
;;;;     returns   -- (values body-string fault-p)
;;;;
;;;; The transport layer (src/soap.lisp, src/routing.lisp, src/maildir.lisp,
;;;; src/reply.lisp, src/main.lisp) has no dependency on this file.

(in-package #:com.dwightaspencer.soap-example)

;;; Calculator service namespace -- owned by this example, not the transport.
;;; The transport passes it to build-soap-envelope as :extra-namespaces.
(defparameter *calc-ns*
  "http://example.com/soap/calculator/")

(defparameter *calc-prefix* "cal")

(defun dispatch-soap (operation)
  "Dispatch a parsed SOAP operation node for the calculator service.
   Returns (values body-content-string fault-p).
   This is the example handler -- wire it into main via the :handler arg."
  (let ((op-name (soap-operation-name operation)))
    (cond
      ((member op-name '("Add" "Subtract" "Multiply" "Divide")
               :test #'string-equal)
       (handler-case
           (let ((a (soap-param "intA" operation *calc-ns*))
                 (b (soap-param "intB" operation *calc-ns*)))
             (cond
               ((string-equal "Add"      op-name)
                (values (build-result "Add"      "AddResult"      (+ a b) *calc-prefix*) nil))
               ((string-equal "Subtract" op-name)
                (values (build-result "Subtract" "SubtractResult" (- a b) *calc-prefix*) nil))
               ((string-equal "Multiply" op-name)
                (values (build-result "Multiply" "MultiplyResult" (* a b) *calc-prefix*) nil))
               ((string-equal "Divide"   op-name)
                (if (zerop b)
                    (values (build-fault "Sender" "Division by zero"
                                         "intB must be non-zero") t)
                    (values (build-result "Divide" "DivideResult"
                                          (floor a b) *calc-prefix*) nil)))))
         (error (e)
           (values (build-fault "Sender"
                                (format nil "Invalid parameters: ~A" e)
                                (format nil "Operation: ~A" op-name))
                   t))))
      (t
       (values (build-fault "Sender"
                             (format nil "Unknown operation: ~A" op-name)
                             "Supported operations: Add Subtract Multiply Divide")
               t)))))

(defun calc-envelope (body-content)
  "Wrap BODY-CONTENT in a SOAP envelope with the calculator namespace declared.
   Convenience wrapper for the calculator example -- equivalent to:
     (build-soap-envelope body :extra-namespaces (list (cons *calc-prefix* *calc-ns*)))"
  (build-soap-envelope body-content
                       :extra-namespaces (list (cons *calc-prefix* *calc-ns*))))
