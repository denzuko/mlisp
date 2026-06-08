;;;; src/bounce.lisp — Bounce management (RFC 3464 DSN processing)
;;;;
;;;; Detects Delivery Status Notifications, extracts failed recipients,
;;;; increments bounce counts, removes hard-bouncing addresses at threshold.

(in-package #:mlisp)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; DSN detection and extraction
;;; ─────────────────────────────────────────────────────────────────────────────

(defun dsn-p (headers)
  "Return T if the message appears to be a Delivery Status Notification."
  (let ((ct (string-downcase (or (header-value headers "Content-Type") ""))))
    (or (search "delivery-status" ct)
        (search "multipart/report" ct)
        ;; Fallback: check sender heuristics
        (let ((from (string-downcase (or (header-value headers "From") ""))))
          (or (search "mailer-daemon" from)
              (search "postmaster" from)
              (search "mail-delivery" from))))))

(defun extract-final-recipients (body-lines)
  "Scan BODY-LINES for RFC 3464 Final-Recipient fields.
   Returns list of bare email address strings."
  (let ((recipients '()))
    (dolist (line body-lines)
      (let ((lower (string-downcase line)))
        (when (or (search "final-recipient:" lower)
                  (search "x-failed-recipients:" lower))
          ;; Final-Recipient: rfc822; user@example.com
          (let* ((semi (position #\; line))
                 (addr (if semi
                           (string-trim '(#\Space #\Tab) (subseq line (1+ semi)))
                           (let ((colon (position #\: line)))
                             (when colon
                               (string-trim '(#\Space #\Tab)
                                            (subseq line (1+ colon))))))))
            (when (and addr (position #\@ addr))
              (push (extract-address addr) recipients))))))
    (remove-duplicates recipients :test #'string=)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Bounce processing pipeline
;;; ─────────────────────────────────────────────────────────────────────────────

(defun process-bounce (list-id)
  "Process a DSN message from stdin for LIST-ID.
   Increments bounce counts; removes addresses at threshold."
  (multiple-value-bind (headers body-lines _raw)
      (read-message-from-stdin)
    (declare (ignore _raw))
    (unless (dsn-p headers)
      (format *error-output*
              "mlisp: --mode bounce: message does not appear to be a DSN~%")
      (return-from process-bounce 1))
    (let ((failed (extract-final-recipients body-lines))
          (threshold (list-max-bounces list-id)))
      (dolist (addr failed)
        (when (subscriber-p list-id addr)
          (let ((new-count (increment-bounce list-id addr)))
            (audit-append (list :event :bounce :list list-id
                                :address addr :count new-count))
            (record-metric list-id :bounce)
            (when (>= new-count threshold)
              (format *error-output*
                      "mlisp: bounce threshold (~A) reached for ~A on ~A, removing~%"
                      threshold addr list-id)
              (remove-subscriber list-id addr)
              (audit-append (list :event :bounce-removal :list list-id
                                  :address addr :bounce-count new-count))))))
      (save-state)
      0)))
