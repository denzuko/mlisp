;;;; examples/soap-hello-world/soap-service.lisp
;;;;
;;;; W3C SOAP 1.2 Email Binding (NOTE 3 July 2002) implementation.
;;;;
;;;; Batch processes all unread messages from $MAILDIR/new/, dispatches
;;;; SOAP operations in-process, replies per smart address discovery:
;;;;
;;;;   - List headers present (List-Id:, List-Post:, Mailing-List:,
;;;;     Precedence: list) -> reply to LIST (1:many, subscribers receive
;;;;     the SOAP response; further services on the list can consume it)
;;;;   - No list headers -> reply direct to From: (1:1, private exchange)
;;;;
;;;; Per W3C spec:
;;;;   Content-Type: application/soap+xml (RFC 3902)
;;;;   In-Reply-To: <original Message-ID> (correlation)
;;;;   X-Loop: <service-address> set on all outbound (loop guard)
;;;;   Inbound messages with X-Loop: matching service address are skipped
;;;;
;;;; Marks each processed message read by moving new/ -> cur/ (Maildir).
;;;;
;;;; Designed to run from cron every 5 minutes:
;;;;   */5 * * * * /usr/local/bin/soap-service
;;;;
;;;; fetchmail pulls unread messages into $MAILDIR/new/ before this runs.
;;;;
;;;; Build:
;;;;   sbcl --load build.lisp
;;;;
;;;; Requirements: SBCL, Quicklisp (xmls), sendmail(8)
;;;;
;;;; Environment:
;;;;   MAILDIR              Maildir root (default: ~/Maildir)
;;;;   SOAP_SERVICE_ADDRESS Service email address for From: and X-Loop:
;;;;                        (default: soap-calc@example.com)
;;;;   MLISP_SENDMAIL       sendmail(8) path (default: /usr/sbin/sendmail)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (dolist (path (list
                 (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))
                 #p"/home/claude/quicklisp/setup.lisp"
                 #p"/root/quicklisp/setup.lisp"))
    (when (probe-file path)
      (load path)
      (return)))
  (funcall (find-symbol "QUICKLOAD" (find-package "QL")) :xmls :silent t))

(defpackage #:soap-service
  (:use #:cl #:xmls))

(in-package #:soap-service)

;;; ── Constants ────────────────────────────────────────────────────────────

(defparameter *soap-envelope-ns*
  "http://schemas.xmlsoap.org/soap/envelope/")

(defparameter *soap-encoding-ns*
  "http://schemas.xmlsoap.org/soap/encoding/")

(defparameter *calc-ns*
  "http://example.com/soap/calculator/")

(defparameter *soap-media-type*
  "application/soap+xml")                  ; RFC 3902

;;; ── Environment helpers ───────────────────────────────────────────────────

(defun getenv (name &optional default)
  (or (sb-ext:posix-getenv name) default))

(defun maildir-root ()
  (getenv "MAILDIR"
          (namestring (merge-pathnames "Maildir/"
                                       (user-homedir-pathname)))))

(defun service-address ()
  (getenv "SOAP_SERVICE_ADDRESS" "soap-calc@example.com"))

(defun sendmail-path ()
  (getenv "MLISP_SENDMAIL" "/usr/sbin/sendmail"))

;;; ── RFC 5322 message parser ──────────────────────────────────────────────

(defun split-by-newline (str)
  (let ((lines '()) (start 0))
    (loop for i from 0 below (length str) do
      (when (char= (char str i) #\Newline)
        (let ((end (if (and (> i 0) (char= (char str (1- i)) #\Return))
                       (1- i) i)))
          (push (subseq str start end) lines)
          (setf start (1+ i)))))
    (when (< start (length str))
      (push (subseq str start) lines))
    (nreverse lines)))

(defun trim (str)
  (string-trim '(#\Space #\Tab #\Return #\Newline) str))

(defun parse-message (raw)
  "Parse RFC 5322 message into (values headers body).
   Headers is an alist (name . value). Body is the string after
   the first blank line. Handles folded headers (RFC 5322 §2.2.3)."
  (let ((lines (split-by-newline raw))
        (headers '())
        (body-lines '())
        (in-body nil))
    (dolist (line lines)
      (cond
        (in-body
         (push line body-lines))
        ((zerop (length (trim line)))
         (setf in-body t))
        ;; Folded header continuation (starts with WSP)
        ((and (> (length line) 0)
              (member (char line 0) '(#\Space #\Tab)))
         (when headers
           (setf (cdar headers)
                 (concatenate 'string (cdar headers) " " (trim line)))))
        (t
         (let ((colon (position #\: line)))
           (when colon
             (push (cons (trim (subseq line 0 colon))
                         (trim (subseq line (1+ colon))))
                   headers))))))
    (values (nreverse headers)
            (with-output-to-string (s)
              (dolist (l (nreverse body-lines))
                (write-string l s)
                (write-char #\Newline s))))))

(defun header (name headers)
  "Case-insensitive header lookup. Returns value string or nil."
  (cdr (assoc name headers :test #'string-equal)))

;;; ── Loop guard ───────────────────────────────────────────────────────────

(defun x-loop-p (headers)
  "Return T if this message has our service's X-Loop: header set,
   indicating it is our own reply and should not be reprocessed."
  (let ((loop-val (header "X-Loop" headers)))
    (and loop-val
         (string-equal (trim loop-val) (service-address)))))

;;; ── Mailing list detection (RFC 2369, RFC 2919) ──────────────────────────

(defun list-message-p (headers)
  "Return T if this message was delivered through a mailing list.
   Checks per RFC 2369 (List-*) and RFC 2919 (List-Id) headers,
   plus common MTA conventions (Precedence: list/bulk, Mailing-List:)."
  (or (header "List-Id"      headers)      ; RFC 2919
      (header "List-Post"    headers)      ; RFC 2369
      (header "List-Help"    headers)      ; RFC 2369
      (header "List-Archive" headers)      ; RFC 2369
      (header "Mailing-List" headers)      ; Mailman/ezmlm convention
      (let ((prec (header "Precedence" headers)))
        (and prec (member (string-downcase (trim prec))
                          '("list" "bulk")
                          :test #'string=)))))

(defun list-reply-address (headers)
  "Extract the list posting address from List-Post: header (RFC 2369).
   Falls back to the inbound To: address (the list address the request
   was sent to). Returns address string."
  (let ((list-post (header "List-Post" headers)))
    (if list-post
        ;; List-Post: <mailto:list@example.com> -> extract the address
        (let* ((start (position #\< list-post))
               (end   (position #\> list-post :start (or start 0))))
          (if (and start end)
              (let ((mailto (subseq list-post (1+ start) end)))
                ;; Strip leading "mailto:" if present
                (if (string-equal "mailto:" mailto :end2 (min 7 (length mailto)))
                    (subseq mailto 7)
                    mailto))
              ;; Malformed List-Post -- fall back to To:
              (header "To" headers)))
        ;; No List-Post: -- use the To: address (the list address)
        (header "To" headers))))

;;; ── Reply address discovery (W3C SOAP 1.2 Email Binding §4.2.3) ─────────

(defun reply-to-address (headers)
  "Discover the correct reply address per W3C SOAP 1.2 Email Binding:
     sender-node-uri = From: of the request  (direct 1:1)
   When the message arrived via a mailing list (detected from RFC 2369/
   2919 headers and Precedence:), the list address is the transport
   endpoint and all subscribers -- including downstream SOAP consumers --
   should receive the response:
     list-address    = List-Post: or To: of the request (1:many)
   Returns (values address mode) where mode is :list or :direct."
  (if (list-message-p headers)
      (values (list-reply-address headers) :list)
      (values (header "From" headers) :direct)))

;;; ── SOAP XML helpers (using xmls) ────────────────────────────────────────

(defun find-child (local-name ns node)
  "Find first child of NODE with given local name and namespace URI."
  (dolist (child (xmls:node-children node))
    (when (and (xmls:node-p child)
               (string-equal local-name (xmls:node-name child))
               (or (null ns)
                   (equal ns (xmls:node-ns child))))
      (return child))))

(defun child-text (local-name ns node)
  "Return text content of the first matching child element."
  (let ((child (find-child local-name ns node)))
    (when child
      (let ((children (xmls:node-children child)))
        (when (and children (stringp (car children)))
          (trim (car children)))))))

(defun parse-soap-envelope (body-string)
  "Parse the message body as a SOAP 1.2 envelope.
   Returns (values envelope soap-body operation) or signals an error."
  (handler-case
      (let* ((doc      (xmls:parse body-string))
             (envelope doc)
             (body-el  (find-child "Body" *soap-envelope-ns* envelope))
             (op       (when body-el
                         (dolist (c (xmls:node-children body-el))
                           (when (xmls:node-p c)
                             (return c))))))
        (unless (string-equal "Envelope" (xmls:node-name envelope))
          (error "Root element is not soap:Envelope"))
        (unless body-el
          (error "No soap:Body found in envelope"))
        (unless op
          (error "soap:Body is empty"))
        (values envelope body-el op))
    (error (e)
      (error "SOAP parse error: ~A" e))))

;;; ── SOAP envelope builders ───────────────────────────────────────────────

(defun build-envelope (body-content-string)
  "Wrap body-content-string in a SOAP 1.2 envelope."
  (format nil
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>~%~
     <env:Envelope~%~
         xmlns:env=\"~A\"~%~
         xmlns:cal=\"~A\">~%~
       <env:Body>~%~
     ~A~
       </env:Body>~%~
     </env:Envelope>~%"
    *soap-envelope-ns*
    *calc-ns*
    body-content-string))

(defun build-result (op-name result-name value)
  (format nil "    <cal:~AResponse>~%      <cal:~A>~A</cal:~A>~%    </cal:~AResponse>~%"
          op-name result-name value result-name op-name))

(defun build-fault (code reason detail)
  "Build a SOAP 1.2 Fault element."
  (format nil
    "    <env:Fault>~%~
           <env:Code><env:Value>env:~A</env:Value></env:Code>~%~
           <env:Reason><env:Text xml:lang=\"en\">~A</env:Text></env:Reason>~%~
           <env:Detail>~A</env:Detail>~%~
         </env:Fault>~%"
    code reason detail))

;;; ── Calculator dispatch ──────────────────────────────────────────────────

(defun integer-param (name op)
  "Parse named integer parameter from operation element."
  (let ((text (child-text name *calc-ns* op)))
    (unless text
      (error "Missing parameter: ~A" name))
    (multiple-value-bind (val end)
        (parse-integer text :junk-allowed t)
      (unless (and val (= end (length text)))
        (error "Parameter ~A is not an integer: ~S" name text))
      val)))

(defun dispatch (operation)
  "Dispatch SOAP operation. Returns (values response-body-string fault-p)."
  (let ((op-name (xmls:node-name operation)))
    (cond
      ((member op-name '("Add" "Subtract" "Multiply" "Divide")
               :test #'string-equal)
       (handler-case
           (let ((a (integer-param "intA" operation))
                 (b (integer-param "intB" operation)))
             (cond
               ((string-equal op-name "Add")
                (values (build-result "Add" "AddResult" (+ a b)) nil))
               ((string-equal op-name "Subtract")
                (values (build-result "Subtract" "SubtractResult" (- a b)) nil))
               ((string-equal op-name "Multiply")
                (values (build-result "Multiply" "MultiplyResult" (* a b)) nil))
               ((string-equal op-name "Divide")
                (if (zerop b)
                    (values (build-fault "Sender" "Division by zero"
                                         "intB must be non-zero")
                            t)
                    (values (build-result "Divide" "DivideResult"
                                          (floor a b))
                            nil)))))
         (error (e)
           (values (build-fault "Sender"
                                (format nil "Invalid parameters: ~A" e)
                                (format nil "Operation: ~A" op-name))
                   t))))
      (t
       (values (build-fault "Sender"
                             (format nil "Unknown operation: ~A" op-name)
                             "Supported: Add Subtract Multiply Divide")
               t)))))

;;; ── Send reply ───────────────────────────────────────────────────────────

(defun send-reply (to from subject message-id soap-envelope-string mode)
  "Send the SOAP response email.
   MODE is :list (reply to list address) or :direct (reply to caller).
   Sets X-Loop: to prevent the service reprocessing its own reply."
  (let ((proc (sb-ext:run-program (sendmail-path) (list "-t")
                                   :input :stream
                                   :wait nil)))
    (let ((in (sb-ext:process-input proc)))
      ;; Per W3C SOAP 1.2 Email Binding §4.2.3 (Table 9):
      ;;   From: = request-uri (service address)
      ;;   To:   = sender-node-uri (caller) or list address
      ;;   In-Reply-To: = correlation:requestMessageID
      (format in "From: ~A~%"          from)
      (format in "To: ~A~%"            to)
      (format in "Subject: Re: ~A~%"   subject)
      (when message-id
        (format in "In-Reply-To: ~A~%" message-id)
        (format in "References: ~A~%"  message-id))
      ;; X-Loop: guards against the service reprocessing its own reply
      ;; when fetchmail pulls it back in (it will appear in $MAILDIR/new/
      ;; if the service is subscribed to the list it replied to).
      (format in "X-Loop: ~A~%"        from)
      ;; RFC 2369 list reply marker (informational, not required by W3C spec)
      (when (eq mode :list)
        (format in "Precedence: list~%"))
      ;; RFC 3902: application/soap+xml is REQUIRED by W3C SOAP 1.2 Email Binding
      (format in "Content-Type: ~A; charset=utf-8~%"  *soap-media-type*)
      (format in "MIME-Version: 1.0~%")
      (format in "~%")
      (write-string soap-envelope-string in)
      (close in))
    (sb-ext:process-wait proc)))

(defun send-error-reply (to from subject message-id error-text)
  "Send a plain-text error reply when the message body cannot be parsed
   as a valid SOAP envelope (packaging failure per W3C spec §4.2.1)."
  (let ((fault-envelope
          (build-envelope
           (build-fault "Sender" "Bad Request Message" error-text))))
    ;; Even error replies use application/soap+xml where possible;
    ;; if the input wasn't SOAP at all, fall back to text/plain.
    (let ((proc (sb-ext:run-program (sendmail-path) (list "-t")
                                     :input :stream
                                     :wait nil)))
      (let ((in (sb-ext:process-input proc)))
        (format in "From: ~A~%"         from)
        (format in "To: ~A~%"           to)
        (format in "Subject: Re: ~A~%"  subject)
        (when message-id
          (format in "In-Reply-To: ~A~%" message-id)
          (format in "References: ~A~%"  message-id))
        (format in "X-Loop: ~A~%"       from)
        (format in "Content-Type: ~A; charset=utf-8~%" *soap-media-type*)
        (format in "MIME-Version: 1.0~%")
        (format in "~%")
        (write-string fault-envelope in)
        (close in))
      (sb-ext:process-wait proc))))

;;; ── Maildir processing ───────────────────────────────────────────────────

(defun ensure-trailing-slash (str)
  (if (char= (char str (1- (length str))) #\/)
      str
      (concatenate 'string str "/")))

(defun maildir-new (maildir)
  "Return pathnames of all files in $MAILDIR/new/."
  (let* ((new-str (concatenate 'string (ensure-trailing-slash maildir) "new/"))
         (new-pn  (pathname new-str))
         (wild    (make-pathname :directory (pathname-directory new-pn)
                                 :name :wild
                                 :type :wild)))
    (when (probe-file new-pn)
      (directory wild))))

(defun mark-read (pathname)
  "Move message from new/ to cur/ (Maildir read convention).
   Appends ':2,' flags suffix as required by Maildir spec."
  (let* ((filename (file-namestring pathname))
         ;; Maildir flags: strip existing info field if present, add :2,
         (base     (let ((colon (position #\: filename)))
                     (if colon (subseq filename 0 colon) filename)))
         (cur-path (merge-pathnames
                    (format nil "cur/~A:2," base)
                    (make-pathname :directory
                                   (butlast (pathname-directory pathname)))))
         (cur-dir  (make-pathname
                    :directory (pathname-directory cur-path))))
    (ensure-directories-exist cur-dir)
    (rename-file pathname cur-path)))

(defun slurp-file (pathname)
  "Read entire file as a string."
  (with-open-file (s pathname :external-format :utf-8)
    (let ((buf (make-string (file-length s))))
      (read-sequence buf s)
      buf)))

(defun process-message (pathname service-addr)
  "Process one Maildir message file. Returns :processed, :skipped, or :error."
  (handler-case
      (let* ((raw     (slurp-file pathname))
             (headers (nth-value 0 (parse-message raw)))
             (body    (nth-value 1 (parse-message raw))))
        ;; Skip messages with our own X-Loop: header
        (when (x-loop-p headers)
          (mark-read pathname)
          (return-from process-message :skipped))
        ;; Skip messages that don't have application/soap+xml (RFC 3902)
        ;; or have no Content-Type at all -- but be lenient: if there's
        ;; no Content-Type, try to parse anyway (some clients omit it).
        (let ((content-type (header "Content-Type" headers)))
          (when (and content-type
                     (not (search "soap+xml" (string-downcase content-type))))
            (mark-read pathname)
            (return-from process-message :skipped)))
        (let ((from       (header "From"       headers))
              (subject    (or (header "Subject" headers) "SOAP Service"))
              (message-id (header "Message-ID" headers)))
          (unless from
            (mark-read pathname)
            (return-from process-message :skipped))
          ;; Discover reply path
          (multiple-value-bind (reply-to mode)
              (reply-to-address headers)
            ;; Parse the SOAP envelope
            (handler-case
                (multiple-value-bind (envelope body-el operation)
                    (parse-soap-envelope (trim body))
                  (declare (ignore envelope body-el))
                  ;; Dispatch the operation
                  (multiple-value-bind (response-body fault-p)
                      (dispatch operation)
                    (declare (ignore fault-p))
                    (let ((soap-response (build-envelope response-body)))
                      (send-reply reply-to service-addr subject
                                  message-id soap-response mode))))
              (error (e)
                (send-error-reply (or reply-to from) service-addr
                                  subject message-id
                                  (format nil "~A" e)))))
          (mark-read pathname)
          :processed))
    (error (e)
      (format *error-output*
              "soap-service: error processing ~A: ~A~%"
              (file-namestring pathname) e)
      :error)))

;;; ── Main entry point ─────────────────────────────────────────────────────

(defun main ()
  (let* ((maildir      (maildir-root))
         (service-addr (service-address))
         (messages     (maildir-new maildir)))
    (unless messages
      (sb-ext:exit :code 0))
    (let ((processed 0) (skipped 0) (errors 0))
      (dolist (msg messages)
        (case (process-message msg service-addr)
          (:processed (incf processed))
          (:skipped   (incf skipped))
          (:error     (incf errors))))
      (format *error-output*
              "soap-service: ~A processed, ~A skipped, ~A errors~%"
              processed skipped errors)))
  (sb-ext:exit :code 0))

;;; ── Entry point guard ───────────────────────────────────────────────────
;;; Only call main when running as a binary (sb-ext:*runtime-pathname*
;;; is set when dumped via save-lisp-and-die). During build-time load
;;; (build.lisp) this form is not evaluated.
(eval-when (:execute)
  (unless (and (boundp 'cl-user::*soap-service-building*)
               cl-user::*soap-service-building*)
    (main)))
