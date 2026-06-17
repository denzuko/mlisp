;;;; src/main.lisp -- main entry point for soap-service
;;;;
;;;; Batch processes all unread messages in $MAILDIR/new/.
;;;; Uses cl-mime (mime:parse-mime, mime:parse-headers) for message parsing.

(in-package #:soap-service)

(defun getenv (name &optional default)
  (or (sb-ext:posix-getenv name) default))

(defun service-address ()
  (getenv "SOAP_SERVICE_ADDRESS" "soap-calc@example.com"))

(defun process-one (pathname service-addr)
  "Process a single Maildir message. Returns :processed, :skipped, or :error."
  (handler-case
      (let* ((raw     (slurp-file pathname))
             ;; cl-mime parses headers into (:KEYWORD . "value") alist
             (headers (mime:parse-headers (make-string-input-stream raw)))
             ;; cl-mime parses the whole message into a MIME object
             (parsed  (mime:parse-mime raw))
             (body    (or (mime:content parsed) "")))

        ;; Guard: skip our own replies (X-Loop: matches service address)
        (when (x-loop-p headers service-addr)
          (mark-read pathname)
          (return-from process-one :skipped))

        ;; Guard: skip non-SOAP content-types (lenient if absent)
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

          ;; Discover reply path from RFC 2369/2919 list headers
          (multiple-value-bind (reply-to mode)
              (reply-to-address headers)

            ;; Parse and dispatch the SOAP envelope
            (handler-case
                (let* ((op       (parse-soap-envelope (trim body)))
                       (body-str (nth-value 0 (dispatch-soap op)))
                       (envelope (build-soap-envelope body-str)))
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
