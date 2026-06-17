;;;; src/main.lisp -- main entry point for soap-service
;;;;
;;;; Batch processes all unread messages in $MAILDIR/new/:
;;;;   1. Skip messages with X-Loop: matching our service address
;;;;   2. Skip messages with non-SOAP Content-Type
;;;;   3. Parse the SOAP envelope
;;;;   4. Dispatch the operation
;;;;   5. Discover reply address (list vs direct)
;;;;   6. Send reply with X-Loop: set
;;;;   7. Mark message read (new/ -> cur/)

(in-package #:soap-service)

(defun process-one (pathname service-addr)
  "Process a single Maildir message. Returns :processed, :skipped, or :error."
  (handler-case
      (let* ((raw     (slurp-file pathname))
             (headers (nth-value 0 (parse-message raw)))
             (body    (nth-value 1 (parse-message raw))))
        ;; Guard: skip our own replies
        (when (x-loop-p headers service-addr)
          (mark-read pathname)
          (return-from process-one :skipped))
        ;; Guard: skip non-SOAP content-types (but be lenient if absent)
        (let ((ct (header "Content-Type" headers)))
          (when (and ct (not (soap-content-type-p ct)))
            (mark-read pathname)
            (return-from process-one :skipped)))
        (let ((from       (header "From"       headers))
              (subject    (or (header "Subject" headers) "SOAP Response"))
              (message-id (header "Message-ID" headers)))
          (unless from
            (mark-read pathname)
            (return-from process-one :skipped))
          ;; Discover reply address
          (multiple-value-bind (reply-to mode)
              (reply-to-address headers)
            ;; Parse and dispatch
            (handler-case
                (let* ((op       (parse-soap-envelope (trim body)))
                       (body-str (nth-value 0 (dispatch-soap op)))
                       (envelope (build-soap-envelope body-str)))
                  (send-reply reply-to service-addr subject
                              message-id envelope mode))
              (error (e)
                ;; Unparseable envelope -> reply with soap:Fault
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

(defun main ()
  "Batch process all unread messages in $MAILDIR/new/."
  (let* ((maildir      (getenv "MAILDIR"
                                (namestring (merge-pathnames "Maildir/"
                                             (user-homedir-pathname)))))
         (service-addr (service-address))
         (messages     (maildir-new maildir)))
    (unless messages
      (sb-ext:exit :code 0))
    (let ((processed 0) (skipped 0) (errors 0))
      (dolist (msg messages)
        (case (process-one msg service-addr)
          (:processed (incf processed))
          (:skipped   (incf skipped))
          (:error     (incf errors))))
      (format *error-output*
              "soap-service: ~A processed, ~A skipped, ~A errors~%"
              processed skipped errors)))
  (sb-ext:exit :code 0))
