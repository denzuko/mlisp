;;;; src/mta.lisp — Audit log (GDPR Art.30), MTA delivery, admin command handlers

(in-package #:mlisp)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Audit log (GDPR Art. 30 records of processing activity)
;;; ─────────────────────────────────────────────────────────────────────────────

(defun audit-append (event-plist)
  "Append EVENT-PLIST to the audit log, creating file if needed.
   GDPR Art.30 records of processing activity."
  (ignore-errors
    (ensure-directories-exist (audit-path))
    (with-open-file (s (audit-path)
                       :direction :output
                       :if-exists :append
                       :if-does-not-exist :create)
      (let ((*print-pretty*   nil)
            (*print-case*     :downcase)
            (*print-readably* nil)
            (*print-escape*   t))
        (write (list* :timestamp (iso8601-now) event-plist) :stream s)
        (terpri s)))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; MTA delivery
;;; ─────────────────────────────────────────────────────────────────────────────

(defun sendmail (recipients body-string &key (extra-headers '()))
  "Fork sendmail(8) to deliver BODY-STRING to RECIPIENTS list.
   Broken-pipe on the input stream is silently ignored."
  (let ((proc (sb-ext:run-program (sendmail-path)
                                  (list* "-oi" recipients)
                                  :input :stream
                                  :output nil
                                  :error nil
                                  :wait nil)))
    (ignore-errors
      (let ((s (sb-ext:process-input proc)))
        (dolist (h extra-headers)
          (format s "~A: ~A~%" (car h) (cdr h)))
        (write-string body-string s)
        (finish-output s)
        (close s)))
    (sb-ext:process-wait proc)
    (sb-ext:process-exit-code proc)))

(defun tag-subject (subject list-id)
  "Prepend [LIST-ID] to SUBJECT if not already present (CAN-SPAM § 7704(a)(1))."
  (let ((tag (format nil "[~A] " list-id)))
    (if (search (string-downcase tag) (string-downcase subject))
        subject
        (concatenate 'string tag subject))))

(defun compliance-footer-text (list-id)
  "Return plain-text compliance footer for LIST-ID.
   CAN-SPAM § 7704(a)(3)(A): unsubscribe mechanism.
   CAN-SPAM § 7704(a)(5)(A): physical postal address."
  (let* ((drop   (list-drop-address list-id))
         (addr   (list-postal-address list-id))
         (purl   (list-privacy-url list-id))
         (line   (make-string 72 :initial-element #\-)))
    (format nil "~%~A~%~
You are receiving this because you subscribed to the ~A list.~%~
~%~
To unsubscribe, send email to ~A~%~
with subject line: unsubscribe~%~
~%~
Privacy: ~A~%~
~%~
~A~%~
~A~%~A~%"
            line list-id drop purl line addr line)))

(defun rfc2369-headers (list-id)
  "Return RFC 2369 List-* and Usenet crossover headers as an alist."
  (let* ((drop (list-drop-address list-id))
         (req  (list-request-address list-id))
         (lid  (format nil "<~A.mlisp.dapla.net>" list-id)))
    (list
     (cons "List-Id"          lid)
     (cons "List-Post"        (format nil "<mailto:~A>" drop))
     (cons "List-Help"        (format nil "<mailto:~A?subject=help>" req))
     (cons "List-Subscribe"   (format nil "<mailto:~A?subject=subscribe>" req))
     (cons "List-Unsubscribe" (format nil "<mailto:~A?subject=unsubscribe>" req))
     (cons "X-Mailing-List"   (format nil "<~A>" drop))
     (cons "X-BeenThere"      drop)
     (cons "Precedence"       "list"))))

(defun distribute-message (list-id _from-addr headers body-lines)
  "Deliver individually to each subscriber (BCC privacy).
   Strips MIME; injects RFC 2369 List-* headers, Usenet headers,
   Precedence: list, subject tag, compliance footer."
  (let* ((addrs       (subscriber-addresses list-id))
         (drop        (list-drop-address list-id))
         (loop-hdr    (list-loop-header list-id))
         (raw-subject (or (header-value headers "Subject") "(no subject)"))
         (tagged-subj (tag-subject raw-subject list-id))
         (footer      (compliance-footer-text list-id))
         (clean-body  (process-body-for-distribution headers body-lines))
         (extra-hdrs
          (append
           (rfc2369-headers list-id)
           (list (cons loop-hdr   "1")
                 (cons "Sender"   drop)
                 (cons "Reply-To" drop)
                 (cons "Subject"  tagged-subj)
                 (cons "To"       drop))))
         (msg-body
          (with-output-to-string (s)
            (dolist (h headers)
              (unless (member (car h)
                              '("SENDER" "REPLY-TO" "SUBJECT" "TO" "CC"
                                "CONTENT-TYPE" "CONTENT-TRANSFER-ENCODING"
                                "CONTENT-DISPOSITION" "MIME-VERSION"
                                "LIST-ID" "X-MAILING-LIST" "PRECEDENCE")
                              :test #'string=)
                (format s "~A: ~A~%" (car h) (cdr h))))
            (terpri s)
            (write-string clean-body s)
            (write-string footer s))))
    ;; Individual delivery — no subscriber address exposure
    (dolist (addr addrs)
      (sendmail (list addr) msg-body :extra-headers extra-hdrs))
    (record-metric list-id :distributed)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Administrative command handlers
;;; ─────────────────────────────────────────────────────────────────────────────

(defun command-reply-headers (list-id subject-str)
  "Return standard extra-headers for command reply messages.
   Includes RFC 8098 MDN header for delivery tracking (no pixels)."
  (let ((req (list-request-address list-id)))
    (list (cons "Subject"    subject-str)
          (cons "From"       (list-drop-address list-id))
          (cons "Precedence" "bulk")
          ;; RFC 8098 / RFC 3461: email-level delivery notification only
          ;; No tracking pixels, no URLs, no cookies.
          (cons "Disposition-Notification-To" req)
          (cons "Return-Receipt-To"           req))))

(defun handle-subscribe (list-id sender)
  (add-subscriber list-id sender)
  (save-state)
  (audit-append (list :event :subscribe :list list-id :address sender))
  (record-metric list-id :subscribe)
  (let ((body (handler-case
                  (render-template list-id "welcome")
                (error () (format nil "You have been subscribed to ~A.~%" list-id)))))
    (sendmail (list sender) body
              :extra-headers (command-reply-headers
                              list-id
                              (format nil "Welcome to ~A" list-id)))))

(defun handle-unsubscribe (list-id sender)
  ;; GDPR Art.17 erasure: remove then audit
  (remove-subscriber list-id sender)
  (save-state)
  (audit-append (list :event :unsubscribe :list list-id :address sender))
  (record-metric list-id :unsubscribe)
  (let ((body (handler-case
                  (render-template list-id "goodbye")
                (error () (format nil "You have been unsubscribed from ~A.~%" list-id)))))
    (sendmail (list sender) body
              :extra-headers (command-reply-headers
                              list-id
                              (format nil "Unsubscribed from ~A" list-id)))))

(defun handle-help (list-id sender)
  (let ((body (handler-case
                  (render-template list-id "help")
                (error ()
                  (format nil "~
List: ~A~%~
Commands: subscribe, unsubscribe, help~%~
Send commands in Subject or first line of body.~%" list-id)))))
    (sendmail (list sender) body
              :extra-headers (command-reply-headers
                              list-id
                              (format nil "Help: ~A mailing list" list-id)))))

(defun handle-reject (list-id sender)
  "Send typeset rejection notice to SENDER."
  (let ((body
         (handler-case
             (render-troff-to-text
              (sexp->troff
               `(:document
                 (:title "Submission Rejected")
                 (:author ,(list-drop-address list-id))
                 (:p ,(format nil "Your message to the ~A list has been rejected." list-id))
                 (:p "You are not a subscriber of this list.")
                 (:p "To subscribe, send a message with the subject: subscribe"))))
           (error ()
             (format nil "Your submission to ~A was rejected: not a subscriber.~%" list-id)))))
    (sendmail (list sender) body
              :extra-headers (list (cons "Subject"
                                         (format nil "Rejected: ~A" list-id))
                                   (cons "From"
                                         (list-drop-address list-id))))))
