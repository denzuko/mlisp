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

(defun windowed-increment-bounce (list-id address action-str)
  "Increment bounce count for ADDRESS using time-windowed multigram logic.
   ACTION-STR is the DSN Action: field value (failed/delayed/etc).
   Returns T if bounce count reached removal threshold."
  (let* ((is-hard  (not (search "delayed" (string-downcase (or action-str "")))))
         (new-cnt  (increment-bounce list-id address :hard is-hard))
         (max-b    (list-max-bounces list-id)))
    (and is-hard (>= new-cnt max-b))))

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
          ;; windowed-increment-bounce: handles time-window reset + soft/hard distinction
          ;; extract DSN action field from body if possible
          (let* ((action  (let ((act-line
                                 (find-if (lambda (l)
                                            (search "action:" (string-downcase l)))
                                          body-lines)))
                            (if act-line
                                (string-trim " " (subseq act-line
                                                         (1+ (position #\: act-line))))
                                "failed")))  ; default assume hard bounce
                 (remove-p (windowed-increment-bounce list-id addr action))
                 (new-count (subscriber-bounce-count list-id addr)))
            (audit-append (list :event :bounce :list list-id
                                :address addr :count new-count :action action))
            (record-metric list-id :bounce)
            (when remove-p
              (format *error-output*
                      "mlisp: bounce threshold reached for ~A on ~A, removing~%"
                      addr list-id)
              (remove-subscriber list-id addr)
              (audit-append (list :event :bounce-removal :list list-id
                                  :address addr :bounce-count new-count))))))
      (save-state)
      0)))
