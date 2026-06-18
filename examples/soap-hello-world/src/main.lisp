;;;; src/main.lisp -- generic email-SOAP batch processor
;;;;
;;;; The transport layer is fully decoupled from the service implementation.
;;;; The handler and envelope-builder are injected at runtime:
;;;;
;;;;   handler (operation) -> (values body-string fault-p)
;;;;     Receives the xmls operation node, returns SOAP body content.
;;;;
;;;;   envelope-builder (body-string) -> string
;;;;     Wraps body-string in a SOAP envelope. Defaults to
;;;;     #'build-soap-envelope (no extra namespaces), but service
;;;;     implementations supply their own (e.g. calc-envelope) to inject
;;;;     service-specific namespace declarations on the root element.
;;;;
;;;; main calls process-batch with defaults wired to the calculator example.
;;;; A future library would expose process-batch directly; callers supply
;;;; their own :handler and :envelope-builder.

(in-package #:com.dwightaspencer.soap-example)

(defun getenv (name &optional default)
  (or (sb-ext:posix-getenv name) default))

(defun service-address ()
  (getenv "SOAP_SERVICE_ADDRESS" "soap-calc@example.com"))

(defun process-one (pathname service-addr handler envelope-builder)
  "Process a single Maildir message. Returns :processed, :skipped, or :error.
   HANDLER and ENVELOPE-BUILDER are the injected service implementation."
  (handler-case
      (let* ((raw     (slurp-file pathname))
             (headers (mime:parse-headers (make-string-input-stream raw)))
             (parsed  (mime:parse-mime raw))
             (body    (or (mime:content parsed) "")))

        (when (x-loop-p headers service-addr)
          (mark-read pathname)
          (return-from process-one :skipped))

        (when parsed
          (let ((ct  (mime:content-type    parsed))
                (cst (mime:content-subtype parsed)))
            (when (and ct cst (not (soap-content-type-p ct cst)))
              (mark-read pathname)
              (return-from process-one :skipped))))

        (let ((from       (cdr (assoc :from       headers)))
              (subject    (or (cdr (assoc :subject    headers)) "SOAP Response"))
              (message-id (cdr (assoc :message-id headers))))

          (unless from
            (mark-read pathname)
            (return-from process-one :skipped))

          (multiple-value-bind (reply-to mode)
              (reply-to-address headers)
            (handler-case
                (let* ((op       (parse-soap-envelope (trim body)))
                       ;; Injected handler: domain-specific dispatch
                       (body-str (nth-value 0 (funcall handler op)))
                       ;; Injected envelope-builder: namespace-aware wrapping
                       (envelope (funcall envelope-builder body-str)))
                  (send-reply reply-to service-addr subject
                              message-id envelope mode))
              (error (e)
                (let ((fault-env
                        (build-soap-envelope
                         (build-fault "Sender" "Bad request"
                                       (format nil "~A" e)))))
                  (send-reply (or reply-to from) service-addr subject
                              message-id fault-env :direct)))))

          (mark-read pathname)
          :processed))
    (error (e)
      (format *error-output*
              "soap-service: error processing ~A: ~A~%"
              (file-namestring pathname) e)
      (ignore-errors (mark-read pathname))
      :error)))

(defun process-batch (maildir service-addr
                      &key
                      (handler       #'dispatch-soap)
                      (envelope-builder #'calc-envelope))
  "Batch process all unread messages in MAILDIR/new/.
   HANDLER and ENVELOPE-BUILDER are the service implementation hooks.
   Returns (values processed skipped errors)."
  (let ((messages (maildir-new maildir))
        (processed 0) (skipped 0) (errors 0))
    (dolist (msg messages)
      (case (process-one msg service-addr handler envelope-builder)
        (:processed (incf processed))
        (:skipped   (incf skipped))
        (:error     (incf errors))))
    (values processed skipped errors)))

(defun main ()
  "Entry point: batch process $MAILDIR/new/ with the calculator example service."
  (let* ((maildir      (getenv "MAILDIR"
                                (namestring (merge-pathnames "Maildir/"
                                             (user-homedir-pathname)))))
         (service-addr (service-address)))
    (multiple-value-bind (processed skipped errors)
        (process-batch maildir service-addr
                       :handler          #'dispatch-soap
                       :envelope-builder #'calc-envelope)
      (format *error-output*
              "soap-service: ~A processed, ~A skipped, ~A errors~%"
              processed skipped errors)))
  (sb-ext:exit :code 0))
