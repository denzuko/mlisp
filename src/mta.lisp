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

(defun sendmail (recipients body-string &key (extra-headers '()) envelope-sender)
  "Fork sendmail(8) to deliver BODY-STRING to RECIPIENTS list.
   :envelope-sender when provided passes -f <addr> (used for VERP).
   Broken-pipe on the input stream is silently ignored."
  (let* ((base-args (if envelope-sender
                        (list "-oi" "-f" envelope-sender)
                        (list "-oi")))
         (proc (sb-ext:run-program (sendmail-path)
                                   (append base-args recipients)
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

(defun next-message-number (list-id)
  "Increment and return the next message sequence number for LIST-ID.
   Persists the counter to state immediately so it survives across calls."
  (let* ((lst (find-list list-id))
         (n   (1+ (or (getf lst :message-counter) 0))))
    (if (member :message-counter lst)
        (setf (getf lst :message-counter) n)
        (nconc lst (list :message-counter n)))
    (save-state)
    n))

(defun tag-subject (subject list-id)
  "Prepend [LIST-ID] (and optional #NNN) to SUBJECT if not already present."
  (let* ((tag     (format nil "[~A] " list-id))
         (use-num (getf (find-list list-id) :message-numbering))
         (n       (when use-num (next-message-number list-id)))
         (full-tag (if n
                       (format nil "[~A #~3,'0D] " list-id n)
                       tag)))
    (if (search (string-downcase tag) (string-downcase subject))
        subject
        (concatenate 'string full-tag subject))))

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
  "Return RFC 2369/2919/8058 List-* and Usenet crossover headers as an alist."
  (let* ((drop     (list-drop-address list-id))
         (req      (list-request-address list-id))
         ;; RFC 2919: List-Id derives domain from drop-address, not hardcoded
         (at-pos   (position #\@ drop))
         (l-domain (if at-pos (subseq drop (1+ at-pos)) "localhost"))
         (lid      (format nil "<~A.~A>" list-id l-domain))
         (lst      (find-list list-id))
         (unsub-url (getf lst :unsubscribe-url))
         (archive-url (getf lst :archive-url))
         ;; :owner subgroup in same namespace
         (ns        (list-namespace list-id))
         (owner-lst (when ns (find-list (format nil "~A-owner" ns))))
         (owner-drop (when owner-lst (list-drop-address (getf owner-lst :id)))))
    (append
     (list
      (cons "List-Id"          lid)
      (cons "List-Post"        (format nil "<mailto:~A>" drop))
      (cons "List-Help"        (format nil "<mailto:~A?subject=help>" req))
      (cons "List-Subscribe"   (format nil "<mailto:~A?subject=subscribe>" req))
      ;; RFC 8058: include HTTPS URI first when configured
      (if unsub-url
          (cons "List-Unsubscribe"
                (format nil "<~A>, <mailto:~A?subject=unsubscribe>"
                        unsub-url req))
          (cons "List-Unsubscribe"
                (format nil "<mailto:~A?subject=unsubscribe>" req)))
      (cons "X-Mailing-List"   (format nil "<~A>" drop))
      (cons "X-BeenThere"      drop)
      (cons "Precedence"       "list"))
     ;; RFC 8058: List-Unsubscribe-Post only when HTTPS URL configured
     (when unsub-url
       (list (cons "List-Unsubscribe-Post" "List-Unsubscribe=One-Click")))
     ;; List-Archive when configured
     (when archive-url
       (list (cons "List-Archive" (format nil "<~A>" archive-url))))
     ;; List-Owner pointing to -owner subgroup
     (when owner-drop
       (list (cons "List-Owner" (format nil "<mailto:~A>" owner-drop)))))))

(defun verp-encode (list-id subscriber-address)
  "Encode subscriber address into VERP envelope sender.
   Format: <list-local>+<hash8>=<sub-local>=<sub-domain>@<list-domain>"
  (let* ((drop    (list-drop-address list-id))
         (at-l    (position #\@ drop))
         (l-local (if at-l (subseq drop 0 at-l) drop))
         (l-dom   (if at-l (subseq drop (1+ at-l)) "localhost"))
         (at-s    (position #\@ subscriber-address))
         (s-local (if at-s (subseq subscriber-address 0 at-s) subscriber-address))
         (s-dom   (if at-s (subseq subscriber-address (1+ at-s)) "unknown"))
         (hash8   (subseq (sha256-hex (concatenate 'string list-id subscriber-address)) 0 8)))
    (format nil "~A+~A=~A=~A@~A" l-local hash8 s-local s-dom l-dom)))

(defun verp-decode (verp-address)
  "Decode a VERP address back to subscriber email.
   Format: <local>+<hash8>=<sub-local>=<sub-domain>@<domain>"
  (let* ((at  (position #\@ verp-address))
         (loc (if at (subseq verp-address 0 at) verp-address))
         (plus (position #\+ loc :from-end nil)))
    (when plus
      (let* ((encoded (subseq loc (1+ plus)))
             ;; skip the hash8 part: first = is the separator
             (hash-end (position #\= encoded))
             (rest     (when hash-end (subseq encoded (1+ hash-end))))
             ;; rest is sub-local=sub-domain
             (eq-pos   (when rest (position #\= rest :from-end t))))
        (when eq-pos
          (format nil "~A@~A"
                  (subseq rest 0 eq-pos)
                  (subseq rest (1+ eq-pos))))))))

(defun list-verp-p (list-id)
  "Return T if VERP is enabled for LIST-ID."
  (getf (find-list list-id) :verp))

(defun distribute-message (list-id _from-addr headers body-lines)

  "Deliver individually to each subscriber (BCC privacy).
   Strips MIME; injects RFC 2369 List-* headers, Usenet headers,
   Precedence: list, subject tag, compliance footer."
  ;; Strip DKIM-Signature (RFC 6376 §5: invalid after redistribution)
  ;; Preserve inbound Authentication-Results for ARC audit chain
  (let ((auth-res (header-value headers "Authentication-Results")))
    (when auth-res
      (setf headers
            (cons (cons "X-Original-Authentication-Results" auth-res)
                  (remove-if (lambda (h) (string-equal (car h) "Authentication-Results"))
                             headers)))))
  (setf headers (remove-if (lambda (h) (string-equal (car h) "DKIM-Signature")) headers))

  (let* ((addrs       (subscriber-addresses list-id))
         (drop        (list-drop-address list-id))
         (loop-hdr    (list-loop-header list-id))
         (raw-subject (or (header-value headers "Subject") "(no subject)"))
         (tagged-subj  (tag-subject raw-subject list-id))
         (footer       (compliance-footer-text list-id))
         (clean-body   (process-body-for-distribution headers body-lines))
         ;; DMARC rewrite decision
         (orig-from    (header-value headers "From"))
         (dmarc-mode   (let ((raw (getf (find-list list-id) :dmarc-rewrite)))
                         (cond
                           ((or (null raw) (eq raw :none) (equal raw "none")) :none)
                           ((or (eq raw :always) (equal raw "always")) :always)
                           ((or (eq raw :never)  (equal raw "never"))  :never)
                           (t :auto))))
         (rewrite-from-p
          (case dmarc-mode
            (:never  nil)
            (:always t)
            (:auto   ;; Check DNS TXT _dmarc.<domain> for p=reject/quarantine
             (let* ((from-domain
                     (when orig-from
                       (let ((at (position #\@ (or (extract-address orig-from) ""))))
                         (when at (subseq (extract-address orig-from) (1+ at))))))
                    (result
                     (when from-domain
                       (ignore-errors
                         (with-output-to-string (s)
                           (sb-ext:run-program "/usr/bin/dig"
                             (list "+short" "TXT" (format nil "_dmarc.~A" from-domain))
                             :output s :error nil :wait t))))))
               (when result
                 (let ((lower (string-downcase result)))
                   (or (search "p=reject" lower)
                       (search "p=quarantine" lower))))))
            (t nil)))
         (extra-hdrs
          (append
           (rfc2369-headers list-id)
           (list (cons loop-hdr   "1")
                 ;; DMARC rewrite: replace From with list address, move original to Reply-To
                 (if rewrite-from-p
                     (cons "From" (format nil "~A via ~A" list-id orig-from))
                     (cons "From" (or orig-from drop)))
                 (cons "Sender"   drop)
                 (cons "Subject"  tagged-subj)
                 (cons "To"       drop))
           ;; X-Original-From when rewriting
           (when rewrite-from-p
             (list (cons "X-Original-From" orig-from)))
           ;; Reply-To munging
           (let ((munge (getf (find-list list-id) :reply-to-munging)))
             (cond
               ((or (eq munge :list) (equal munge "list"))
                (list (cons "Reply-To" drop)))
               ((or (eq munge :poster) (equal munge "poster"))
                (list (cons "Reply-To"
                            (or (header-value headers "From") drop))))
               (t
                ;; :none or unset — DMARC rewrite uses orig-from; else preserve
                (let ((orig-rt (or (and rewrite-from-p orig-from)
                                   (header-value headers "Reply-To"))))
                  (if orig-rt
                      (list (cons "Reply-To" orig-rt))
                      (list (cons "Reply-To" drop)))))))))
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
      (if (list-verp-p list-id)
          (sendmail (list addr) msg-body :extra-headers extra-hdrs
                    :envelope-sender (verp-encode list-id addr))
          (sendmail (list addr) msg-body :extra-headers extra-hdrs))
      ;; Record successful delivery for multigram bounce reset
      (ignore-errors (record-delivery-success list-id addr)))
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

(defun handle-welcome (list-id sender)
  "Send welcome message to SENDER for LIST-ID (subscriber already added)."
  (let ((body (handler-case
                  (render-template list-id "welcome")
                (error () (format nil "You have been subscribed to ~A.~%" list-id)))))
    (sendmail (list sender) body
              :extra-headers (command-reply-headers
                              list-id
                              (format nil "Welcome to ~A" list-id)))))

(defun handle-subscribe (list-id sender)
  ;; Use hash-aware add when :hash-contacts t
  (if (list-hash-contacts-p list-id)
      (add-subscriber-hashed list-id sender)
      (add-subscriber list-id sender))
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
  ;; GDPR Art.17 erasure: remove then audit (hash-aware)
  (if (list-hash-contacts-p list-id)
      (remove-subscriber-hashed list-id sender)
      (remove-subscriber list-id sender))
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
