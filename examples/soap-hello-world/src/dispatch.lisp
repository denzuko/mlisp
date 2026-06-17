;;;; src/dispatch.lisp -- SOAP operation dispatcher
;;;;
;;;; Implements the calculator operations:
;;;;   Add, Subtract, Multiply, Divide
;;;; Returns (values body-string fault-p).

(in-package #:soap-service)

(defun dispatch-soap (operation)
  "Dispatch a parsed SOAP operation node.
   Returns (values body-content-string fault-p)."
  (let ((op-name (soap-operation-name operation)))
    (cond
      ;; Two-integer arithmetic operations
      ((member op-name '("Add" "Subtract" "Multiply" "Divide")
               :test #'string-equal)
       (handler-case
           (let ((a (soap-param "intA" operation))
                 (b (soap-param "intB" operation)))
             (cond
               ((string-equal "Add"      op-name)
                (values (build-result "Add"      "AddResult"      (+ a b)) nil))
               ((string-equal "Subtract" op-name)
                (values (build-result "Subtract" "SubtractResult" (- a b)) nil))
               ((string-equal "Multiply" op-name)
                (values (build-result "Multiply" "MultiplyResult" (* a b)) nil))
               ((string-equal "Divide"   op-name)
                (if (zerop b)
                    (values (build-fault "Sender" "Division by zero"
                                         "intB must be non-zero") t)
                    (values (build-result "Divide" "DivideResult"
                                          (floor a b)) nil)))))
         (error (e)
           (values
            (build-fault "Sender"
                         (format nil "Invalid parameters: ~A" e)
                         (format nil "Operation: ~A" op-name))
            t))))
      ;; Unknown operation
      (t
       (values
        (build-fault "Sender"
                     (format nil "Unknown operation: ~A" op-name)
                     "Supported operations: Add Subtract Multiply Divide")
        t)))))
