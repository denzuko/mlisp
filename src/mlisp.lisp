;;;; mlisp.lisp — Minimalist Mailing List Processor
;;;; Replaces legacy smartlist; compiled via sb-ext:save-lisp-and-die
;;;; POSIX/SBCL; state persisted as S-expressions in state.sexp
;;;;
;;;; Entry point: (mlisp:main) — reads LIST-ID from argv[1], raw email from stdin

(defpackage #:mlisp
  (:use #:cl)
  (:export #:main #:load-state #:save-state #:process-message))

(in-package #:mlisp)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Constants
;;; ─────────────────────────────────────────────────────────────────────────────

(defun mlisp-home ()
  "Return the runtime base directory, from MLISP_HOME env or binary location."
  (let ((env (sb-ext:posix-getenv "MLISP_HOME")))
    (if (and env (> (length env) 0))
        (if (char= (char env (1- (length env))) #\/)
            env
            (concatenate 'string env "/"))
        (directory-namestring
         (truename sb-ext:*runtime-pathname*)))))

(defun state-path ()
  (merge-pathnames "state/state.sexp" (mlisp-home)))

(defun template-dir ()
  (merge-pathnames "templates/" (mlisp-home)))

(defun sendmail-path ()
  "Return the sendmail(8) binary path, from MLISP_SENDMAIL env or default."
  (or (sb-ext:posix-getenv "MLISP_SENDMAIL") "/usr/sbin/sendmail"))

(defparameter *state* nil "In-memory copy of the state database.")

;;; ─────────────────────────────────────────────────────────────────────────────
;;; State I/O
;;; ─────────────────────────────────────────────────────────────────────────────

(defun load-state ()
  "Read state.sexp from (state-path) into *state*."
  (with-open-file (s (state-path) :direction :input
                                  :if-does-not-exist :error)
    (setf *state* (read s))))

(defun save-state ()
  "Persist *state* back to (state-path).
   Uses lowercase keyword printing for human readability and grep compatibility."
  (with-open-file (s (state-path) :direction :output
                                  :if-exists :supersede)
    (let ((*print-pretty*      t)
          (*print-case*        :downcase)
          (*print-readably*    nil)
          (*print-escape*      t))
      (write *state* :stream s)
      (terpri s))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; State accessors
;;; ─────────────────────────────────────────────────────────────────────────────

(defun find-list (list-id)
  "Return the plist for LIST-ID from state, or NIL."
  (find list-id (getf *state* :lists) :key (lambda (l) (getf l :id)) :test #'string=))

;;; Subscriber records are plists:
;;;   (:address "foo@bar.com"
;;;    :subscribed-at "2026-06-08T12:00:00"
;;;    :consent-method "email-subscribe-command")

(defun list-subscribers (list-id)
  "Return subscriber record list (plists) for LIST-ID."
  (getf (find-list list-id) :subscribers))

(defun subscriber-addresses (list-id)
  "Return flat list of subscriber email address strings for LIST-ID."
  (mapcar (lambda (r) (getf r :address)) (list-subscribers list-id)))

(defun subscriber-p (list-id address)
  "Return T if ADDRESS is subscribed to LIST-ID (case-insensitive)."
  (member (string-downcase address)
          (mapcar #'string-downcase (subscriber-addresses list-id))
          :test #'string=))

(defun iso8601-now ()
  "Return current UTC time as ISO-8601 string YYYY-MM-DDTHH:MM:SS."
  (multiple-value-bind (sec min hr day mon yr)
      (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0D"
            yr mon day hr min sec)))

(defun add-subscriber (list-id address)
  "Add ADDRESS to LIST-ID subscribers with consent metadata. No-op if present."
  (unless (subscriber-p list-id address)
    (let ((lst (find-list list-id)))
      (when lst
        (setf (getf lst :subscribers)
              (cons (list :address (string-downcase address)
                          :subscribed-at (iso8601-now)
                          :consent-method "email-subscribe-command")
                    (getf lst :subscribers)))))))

(defun remove-subscriber (list-id address)
  "Remove ADDRESS from LIST-ID subscribers (GDPR Art.17 erasure)."
  (let ((lst (find-list list-id)))
    (when lst
      (setf (getf lst :subscribers)
            (remove (string-downcase address)
                    (getf lst :subscribers)
                    :key  (lambda (r) (string-downcase (getf r :address)))
                    :test #'string=)))))

(defun list-postal-address (list-id)
  "Return the physical postal address for LIST-ID (CAN-SPAM § 7704(a)(5)(A))."
  (or (getf (find-list list-id) :postal-address)
      "Da Planet Security, 1207 Delaware Ave Ste 103, Wilmington DE 19806, USA"))

(defun list-privacy-url (list-id)
  "Return the privacy policy URL for LIST-ID."
  (or (getf (find-list list-id) :privacy-url)
      "https://dwightspencer.com/privacy"))

(defun list-drop-address (list-id)
  "Return the canonical drop address for LIST-ID."
  (getf (find-list list-id) :drop-address))

(defun list-loop-header (list-id)
  "Return the X-Loop header field name for LIST-ID."
  (format nil "X-Loop-List-~:(~A~)" list-id))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; RFC 2822 header parser (minimal, line-oriented)
;;; ─────────────────────────────────────────────────────────────────────────────

(defun parse-headers (lines)
  "Parse RFC 2822 header lines into an alist of (field . value) strings.
   Stops at first blank line (body separator)."
  (loop with headers = '()
        with current-field = nil
        with current-value = nil
        for line in lines
        do (cond
             ;; blank line = end of headers
             ((string= line "")
              (when current-field
                (push (cons current-field (string-trim '(#\Space #\Tab) current-value))
                      headers))
              (return (nreverse headers)))
             ;; continuation (folded header)
             ((member (char line 0) '(#\Space #\Tab))
              (when current-field
                (setf current-value (concatenate 'string current-value " "
                                                 (string-trim '(#\Space #\Tab) line)))))
             ;; new field
             (t
              (when current-field
                (push (cons current-field (string-trim '(#\Space #\Tab) current-value))
                      headers))
              (let ((colon (position #\: line)))
                (if colon
                    (setf current-field (string-upcase (subseq line 0 colon))
                          current-value (subseq line (1+ colon)))
                    (setf current-field nil current-value nil)))))
        finally
           (when current-field
             (push (cons current-field (string-trim '(#\Space #\Tab) current-value))
                   headers))
           (return (nreverse headers))))

(defun read-message-from-stdin ()
  "Read all lines from *standard-input*.
   Returns (values header-alist body-lines raw-lines).
   Strips trailing CR for CRLF tolerance."
  (flet ((strip-cr (s)
           (if (and (> (length s) 0) (char= (char s (1- (length s))) #\Return))
               (subseq s 0 (1- (length s)))
               s)))
    (let* ((all-lines (loop for line = (read-line *standard-input* nil nil)
                            while line collect (strip-cr line)))
           (sep-pos (position "" all-lines :test #'string=))
           (header-lines (if sep-pos (subseq all-lines 0 sep-pos) all-lines))
           (body-lines   (if sep-pos (subseq all-lines (1+ sep-pos)) '())))
      (values (parse-headers header-lines) body-lines all-lines))))

(defun header-value (headers field)
  "Return value of FIELD (case-insensitive) from HEADERS alist, or NIL."
  (cdr (assoc (string-upcase field) headers :test #'string=)))

(defun extract-address (str)
  "Extract bare email address from 'Display Name <addr>' or plain addr."
  (cond
    ((null str) nil)
    ((find #\< str)
     (let ((s (position #\< str))
           (e (position #\> str)))
       (when (and s e) (string-downcase (subseq str (1+ s) e)))))
    (t (string-downcase (string-trim '(#\Space #\Tab #\Newline) str)))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Command detection (Subject / body first line)
;;; ─────────────────────────────────────────────────────────────────────────────

(defparameter *known-commands* '("subscribe" "unsubscribe" "help")
  "Administrative command keywords.")

(defun detect-command (headers body-lines)
  "Return one of :SUBSCRIBE :UNSUBSCRIBE :HELP or NIL for regular posts."
  (let* ((subject (string-downcase (or (header-value headers "Subject") "")))
         (first-body (string-downcase (or (first body-lines) "")))
         (probe (lambda (s cmd) (search cmd s))))
    (cond
      ((or (funcall probe subject "subscribe")
           (funcall probe first-body "subscribe"))
       (if (or (funcall probe subject "unsubscribe")
               (funcall probe first-body "unsubscribe"))
           :unsubscribe
           :subscribe))
      ((or (funcall probe subject "unsubscribe")
           (funcall probe first-body "unsubscribe"))
       :unsubscribe)
      ((or (funcall probe subject "help")
           (funcall probe first-body "help"))
       :help)
      (t nil))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; troff/groff formatting subsystem
;;; ─────────────────────────────────────────────────────────────────────────────

;;; S-expression DSL for troff -ms macros
;;; Grammar:
;;;   (:document &rest block)
;;;   (:title "string") (:author "string") (:abstract "string")
;;;   (:p "string") (:pp "string")  — paragraph / first indented paragraph
;;;   (:b "string")                  — bold inline
;;;   (:section "heading")
;;;   (:quote "string")
;;;   (:raw "raw troff line")

(defun sexp->troff (form)
  "Compile a single DSL form to a troff -ms string."
  (ecase (car form)
    (:document
     (with-output-to-string (s)
       (format s ".ds CH~%.ds LH~%.ds RH~%")
       (dolist (block (cdr form))
         (write-string (sexp->troff block) s))))
    (:title
     (format nil ".TL~%~A~%.AU~%" (cadr form)))
    (:author
     (format nil "~A~%.AI~%" (cadr form)))
    (:abstract
     (format nil ".AB~%~A~%.AE~%" (cadr form)))
    (:section
     (format nil ".NH 1~%~A~%.LP~%" (cadr form)))
    (:p
     (format nil ".LP~%~A~%" (cadr form)))
    (:pp
     (format nil ".PP~%~A~%" (cadr form)))
    (:b
     (format nil "\\fB~A\\fP" (cadr form)))
    (:quote
     (format nil ".QS~%~A~%.QE~%" (cadr form)))
    (:raw
     (format nil "~A~%" (cadr form)))))

(defun render-troff-to-text (troff-source)
  "Pipe TROFF-SOURCE through groff -ms -Tutf8 -P-c; return rendered string."
  (let* ((proc (sb-ext:run-program "/usr/bin/groff"
                                   '("-ms" "-Tutf8" "-P-c")
                                   :input :stream
                                   :output :stream
                                   :error nil
                                   :wait nil))
         (in-s  (sb-ext:process-input proc))
         (out-s (sb-ext:process-output proc)))
    (write-string troff-source in-s)
    (close in-s)
    (let ((result (with-output-to-string (s)
                    (loop for c = (read-char out-s nil nil)
                          while c do (write-char c s)))))
      (sb-ext:process-wait proc)
      result)))

(defun load-template (list-id template-name)
  "Load templates/<list-id>.<template-name>.sexp and return the DSL form."
  (let ((path (merge-pathnames
               (format nil "~A.~A.sexp" list-id template-name)
               (template-dir))))
    (with-open-file (s path :direction :input :if-does-not-exist :error)
      (read s))))

(defun render-template (list-id template-name &key extra-bindings)
  "Load, optionally substitute EXTRA-BINDINGS, compile and render template."
  (declare (ignore extra-bindings))             ; future: token substitution
  (let* ((form   (load-template list-id template-name))
         (troff  (sexp->troff form)))
    (render-troff-to-text troff)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; MTA delivery
;;; ─────────────────────────────────────────────────────────────────────────────

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Audit log (GDPR Art. 30 records of processing activity)
;;; ─────────────────────────────────────────────────────────────────────────────

(defun audit-path ()
  "Path to the append-only audit event log."
  (merge-pathnames "state/audit.sexp" (mlisp-home)))

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

(defun distribute-message (list-id from-addr headers body-lines)
  "Deliver message to all subscribers of LIST-ID.
   Injects: loop protection, List-Id, Sender, subject tag, compliance footer."
  (let* ((addrs       (subscriber-addresses list-id))
         (drop        (list-drop-address list-id))
         (loop-hdr    (list-loop-header list-id))
         (list-id-val (format nil "<~A.mlisp>" list-id))
         (raw-subject (or (header-value headers "Subject") "(no subject)"))
         (tagged-subj (tag-subject raw-subject list-id))
         (footer      (compliance-footer-text list-id))
         (extra-hdrs
          (list (cons loop-hdr     "1")
                (cons "List-Id"    list-id-val)
                (cons "Sender"     drop)
                (cons "Reply-To"   drop)
                (cons "Subject"    tagged-subj)))
         (msg-body
          (with-output-to-string (s)
            ;; Re-emit headers, replacing Subject with tagged version,
            ;; dropping Sender/Reply-To (we set them above)
            (dolist (h headers)
              (unless (member (car h) '("SENDER" "REPLY-TO" "SUBJECT")
                              :test #'string=)
                (format s "~A: ~A~%" (car h) (cdr h))))
            (terpri s)
            (dolist (line body-lines)
              (write-line line s))
            ;; CAN-SPAM / GDPR compliance footer
            (write-string footer s))))
    (declare (ignore from-addr))
    (sendmail addrs msg-body :extra-headers extra-hdrs)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Administrative command handlers
;;; ─────────────────────────────────────────────────────────────────────────────

(defun handle-subscribe (list-id sender)
  (add-subscriber list-id sender)
  (save-state)
  (audit-append (list :event :subscribe :list list-id :address sender))
  (let ((body (handler-case
                  (render-template list-id "welcome")
                (error () (format nil "You have been subscribed to ~A.~%" list-id)))))
    (sendmail (list sender) body
              :extra-headers (list (cons "Subject"
                                         (format nil "Welcome to ~A" list-id))
                                   (cons "From"
                                         (list-drop-address list-id))))))

(defun handle-unsubscribe (list-id sender)
  ;; GDPR Art.17 erasure: remove then audit
  (remove-subscriber list-id sender)
  (save-state)
  (audit-append (list :event :unsubscribe :list list-id :address sender))
  (let ((body (handler-case
                  (render-template list-id "goodbye")
                (error () (format nil "You have been unsubscribed from ~A.~%" list-id)))))
    (sendmail (list sender) body
              :extra-headers (list (cons "Subject"
                                         (format nil "Unsubscribed from ~A" list-id))
                                   (cons "From"
                                         (list-drop-address list-id))))))

(defun handle-help (list-id sender)
  (let ((body (handler-case
                  (render-template list-id "help")
                (error ()
                  (format nil "~
List: ~A~%~
Commands: subscribe, unsubscribe, help~%~
Send commands in Subject or first line of body.~%" list-id)))))
    (sendmail (list sender) body
              :extra-headers (list (cons "Subject"
                                         (format nil "Help: ~A mailing list" list-id))
                                   (cons "From"
                                         (list-drop-address list-id))))))

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

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Core processing pipeline
;;; ─────────────────────────────────────────────────────────────────────────────

(defun process-message (list-id)
  "Full pipeline: read stdin, parse, dispatch. Returns exit code (0 or 1)."
  (multiple-value-bind (headers body-lines _raw)
      (read-message-from-stdin)
    (declare (ignore _raw))
    (let* ((from-addr (or (extract-address (header-value headers "From"))
                          (extract-address (header-value headers "Return-Path"))
                          "unknown@unknown"))
           (loop-hdr  (list-loop-header list-id)))

      ;; 1. Loop detection
      (when (header-value headers loop-hdr)
        (format *error-output* "mlisp: loop detected on ~A, dropping.~%" list-id)
        (return-from process-message 0))

      ;; 2. Find list
      (unless (find-list list-id)
        (format *error-output* "mlisp: unknown list ~A~%" list-id)
        (return-from process-message 1))

      ;; 3. Command dispatch
      (let ((cmd (detect-command headers body-lines)))
        (case cmd
          (:subscribe
           (handle-subscribe list-id from-addr)
           0)
          (:unsubscribe
           (handle-unsubscribe list-id from-addr)
           0)
          (:help
           (handle-help list-id from-addr)
           0)
          (t
           ;; 4. Subscriber authorization
           (if (subscriber-p list-id from-addr)
               (progn
                 (distribute-message list-id from-addr headers body-lines)
                 (audit-append (list :event :post-distributed
                                     :list list-id :from from-addr))
                 0)
               (progn
                 (handle-reject list-id from-addr)
                 (audit-append (list :event :post-rejected
                                     :list list-id :from from-addr))
                 1))))))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Entry point
;;; ─────────────────────────────────────────────────────────────────────────────

(defun main ()
  "CLI entry point. argv[1] = list-id."
  (let ((args (cdr sb-ext:*posix-argv*)))
    (when (or (null args)
              (member "--help" args :test #'string=)
              (member "-h" args :test #'string=))
      (format t "Usage: mlisp <list-id>~%~
Reads raw email from stdin and routes to the named mailing list.~%")
      (sb-ext:exit :code 0))

    (let ((list-id (string-downcase (first args))))
      (handler-case
          (progn
            (load-state)
            (let ((code (process-message list-id)))
              (sb-ext:exit :code code)))
        (error (e)
          (format *error-output* "mlisp: fatal: ~A~%" e)
          (sb-ext:exit :code 2))))))
