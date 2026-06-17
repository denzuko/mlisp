;;;; examples/soap-hello-world/soap-service.lisp
;;;;
;;;; Standalone email-SOAP Hello World service.
;;;;
;;;; Reads a raw RFC 5322 message from stdin whose body is a SOAP
;;;; envelope. Parses the envelope, dispatches the operation, and
;;;; replies to the original From: address with a SOAP response
;;;; envelope via sendmail(8).
;;;;
;;;; Email is the ONLY transport. No HTTP. No external SOAP endpoint.
;;;; The service implements the operations itself, in-process.
;;;;
;;;; ── Mailing list setup (mlisp) ──────────────────────────────────
;;;;
;;;;   mlisp-admin add-namespace soap soap@example.com
;;;;   mlisp-admin set-option soap-calc drop-address soap-calc@example.com
;;;;
;;;; Then add to .procmailrc (after mlisp's own recipes):
;;;;
;;;;   :0
;;;;   * ^To:.*soap-calc@example\.com
;;;;   | sbcl --script /path/to/examples/soap-hello-world/soap-service.lisp
;;;;
;;;; ── Supported operations ─────────────────────────────────────────
;;;;
;;;;   All use namespace http://example.com/soap/calculator/
;;;;
;;;;   Add(intA, intB)       -> AddResponse(AddResult)
;;;;   Subtract(intA, intB)  -> SubtractResponse(SubtractResult)
;;;;   Multiply(intA, intB)  -> MultiplyResponse(MultiplyResult)
;;;;   Divide(intA, intB)    -> DivideResponse(DivideResult)
;;;;                            (fault on division by zero)
;;;;
;;;; ── Example request email ────────────────────────────────────────
;;;;
;;;;   From: client@example.com
;;;;   To:   soap-calc@example.com
;;;;   Subject: SOAP Calculator
;;;;   Content-Type: text/xml; charset=utf-8
;;;;
;;;;   <?xml version="1.0" encoding="utf-8"?>
;;;;   <soap:Envelope
;;;;       xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"
;;;;       xmlns:cal="http://example.com/soap/calculator/">
;;;;     <soap:Body>
;;;;       <cal:Add>
;;;;         <cal:intA>3</cal:intA>
;;;;         <cal:intB>4</cal:intB>
;;;;       </cal:Add>
;;;;     </soap:Body>
;;;;   </soap:Envelope>
;;;;
;;;; ── Example response email ───────────────────────────────────────
;;;;
;;;;   From: soap-calc@example.com
;;;;   To:   client@example.com
;;;;   Subject: Re: SOAP Calculator
;;;;   Content-Type: text/xml; charset=utf-8
;;;;
;;;;   <?xml version="1.0" encoding="utf-8"?>
;;;;   <soap:Envelope
;;;;       xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"
;;;;       xmlns:cal="http://example.com/soap/calculator/">
;;;;     <soap:Body>
;;;;       <cal:AddResponse>
;;;;         <cal:AddResult>7</cal:AddResult>
;;;;       </cal:AddResponse>
;;;;     </soap:Body>
;;;;   </soap:Envelope>
;;;;
;;;; ── Requirements ─────────────────────────────────────────────────
;;;;   SBCL, sendmail(8) or compatible.
;;;;   No external Quicklisp packages -- pure SBCL + built-ins only.
;;;;   XML parsing is done with a minimal hand-written recursive
;;;;   descent parser sufficient for well-formed SOAP 1.1 envelopes.
;;;;   For production use, replace with xmls or cxml via Quicklisp.

;;; ── Utilities ────────────────────────────────────────────────────────────

(defun getenv (name &optional default)
  (or (sb-ext:posix-getenv name) default))

(defun string-trim* (str)
  (string-trim '(#\Space #\Tab #\Newline #\Return) str))

(defun string-starts-with (prefix str)
  (and (>= (length str) (length prefix))
       (string= prefix str :end2 (length prefix))))

(defun string-ends-with (suffix str)
  (and (>= (length str) (length suffix))
       (string= suffix str :start2 (- (length str) (length suffix)))))

;;; ── Minimal RFC 5322 parser ──────────────────────────────────────────────

(defun parse-email (raw)
  "Parse RAW string into (values headers body-string).
   Headers is an alist of (name . value) string pairs.
   Body is everything after the first blank line."
  (let* ((lines (split-lines raw))
         (headers '())
         (body-start 0)
         (in-body nil))
    (loop for line in lines
          for i from 0
          until in-body
          do (cond
               ((zerop (length (string-trim* line)))
                (setf in-body t body-start (1+ i)))
               ((and (> (length line) 0)
                     (member (char line 0) '(#\Space #\Tab)))
                ;; Folded header continuation
                (when headers
                  (setf (cdar headers)
                        (concatenate 'string (cdar headers) " "
                                     (string-trim* line)))))
               (t
                (let ((colon (position #\: line)))
                  (when colon
                    (push (cons (string-trim* (subseq line 0 colon))
                                (string-trim* (subseq line (1+ colon))))
                          headers))))))
    (values (nreverse headers)
            (join-lines (nthcdr body-start lines)))))

(defun split-lines (str)
  "Split STR on LF or CRLF, returning a list of line strings."
  (let ((lines '()) (start 0))
    (loop for i from 0 below (length str)
          do (when (char= (char str i) #\Newline)
               (let* ((end (if (and (> i 0) (char= (char str (1- i)) #\Return))
                               (1- i) i))
                      (line (subseq str start end)))
                 (push line lines)
                 (setf start (1+ i)))))
    (when (< start (length str))
      (push (subseq str start) lines))
    (nreverse lines)))

(defun join-lines (lines)
  (with-output-to-string (s)
    (dolist (l lines)
      (write-string l s)
      (write-char #\Newline s))))

(defun header (name headers)
  "Case-insensitive header lookup."
  (cdr (assoc name headers :test #'string-equal)))

;;; ── Minimal SOAP XML parser ──────────────────────────────────────────────
;;; Parses well-formed SOAP 1.1 envelopes into a simple nested list:
;;;   (:element "local-name" "ns-uri" ((:attr "name" "val") ...) (children...))
;;;   (:text "content")

(defun parse-xml (str)
  "Parse a simple XML string into a nested s-expr tree.
   Not a full XML parser -- handles typical SOAP envelopes only:
   no CDATA, no DTD, no processing instructions beyond <?xml ...?>.
   Sufficient for well-formed SOAP 1.1 with namespace prefixes."
  (let ((pos 0)
        (len (length str)))
    (labels
        ((skip-whitespace ()
           (loop while (and (< pos len)
                            (member (char str pos) '(#\Space #\Tab #\Newline #\Return)))
                 do (incf pos)))
         (read-until (ch)
           (let ((start pos))
             (loop until (or (>= pos len) (char= (char str pos) ch))
                   do (incf pos))
             (subseq str start pos)))
         (read-name ()
           (let ((start pos))
             (loop while (and (< pos len)
                              (let ((c (char str pos)))
                                (or (alphanumericp c)
                                    (member c '(#\- #\_ #\. #\: #\/)))))
                   do (incf pos))
             (subseq str start pos)))
         (read-attribute-value ()
           (let ((q (char str pos)))
             (incf pos) ; opening quote
             (let ((val (read-until q)))
               (incf pos) ; closing quote
               val)))
         (read-attributes ()
           (let ((attrs '()))
             (loop
               (skip-whitespace)
               (when (or (>= pos len)
                         (member (char str pos) '(#\> #\/)))
                 (return attrs))
               (let ((name (read-name)))
                 (skip-whitespace)
                 (if (and (< pos len) (char= (char str pos) #\=))
                     (progn
                       (incf pos)
                       (skip-whitespace)
                       (let ((val (read-attribute-value)))
                         (push (list :attr name val) attrs)))
                     (push (list :attr name "") attrs))))
             (nreverse attrs)))
         (read-element ()
           (skip-whitespace)
           (when (>= pos len) (return-from read-element nil))
           ;; Skip <?...?> and <!--...-->
           (when (and (char= (char str pos) #\<)
                      (< (1+ pos) len))
             (cond
               ((and (char= (char str (1+ pos)) #\?)
                     (string-starts-with "<?" (subseq str pos)))
                (loop until (and (< pos (- len 1))
                                 (char= (char str pos) #\?)
                                 (char= (char str (1+ pos)) #\>))
                      do (incf pos))
                (incf pos 2)
                (return-from read-element (read-element)))
               ((string-starts-with "<!--" (subseq str pos))
                (loop until (string-starts-with "-->" (subseq str pos))
                      do (incf pos))
                (incf pos 3)
                (return-from read-element (read-element)))))
           (cond
             ;; Opening tag
             ((and (< pos len) (char= (char str pos) #\<)
                   (< (1+ pos) len)
                   (not (char= (char str (1+ pos)) #\/)))
              (incf pos) ; skip <
              (let* ((raw-name (read-name))
                     (prefix   (let ((c (position #\: raw-name)))
                                 (if c (subseq raw-name 0 c) nil)))
                     (local    (if prefix
                                   (subseq raw-name (1+ (length prefix)))
                                   raw-name))
                     (attrs    (read-attributes)))
                ;; Resolve namespace URI from xmlns:prefix attribute
                (let* ((ns-uri (if prefix
                                   (let ((a (find-if
                                             (lambda (a)
                                               (string= (cadr a)
                                                        (format nil "xmlns:~A" prefix)))
                                             attrs)))
                                     (if a (caddr a) ""))
                                   ""))
                       (children '()))
                  (skip-whitespace)
                  (cond
                    ;; Self-closing tag
                    ((and (< pos len) (char= (char str pos) #\/))
                     (incf pos 2) ; skip />
                     (list :element local ns-uri attrs nil))
                    (t
                     (incf pos) ; skip >
                     ;; Read children until closing tag
                     (loop
                       (skip-whitespace)
                       (when (>= pos len) (return))
                       (when (and (char= (char str pos) #\<)
                                  (< (1+ pos) len)
                                  (char= (char str (1+ pos)) #\/))
                         (return))
                       (let ((child (read-element)))
                         (when child (push child children))))
                     ;; Skip closing tag
                     (when (and (< pos len) (char= (char str pos) #\<))
                       (loop until (or (>= pos len) (char= (char str pos) #\>))
                             do (incf pos))
                       (incf pos))
                     (list :element local ns-uri attrs
                           (nreverse children)))))))
             ;; Text node
             (t
              (let ((text (string-trim* (read-until #\<))))
                (when (> (length text) 0)
                  (list :text text)))))))
      (read-element))))

(defun xml-local (node) (cadr node))
(defun xml-ns    (node) (caddr node))
(defun xml-attrs (node) (cadddr node))
(defun xml-children (node)
  (when (and (listp node) (eq (car node) :element))
    (fifth node)))

(defun xml-find-child (local-name node)
  "Find first child element with matching local name (case-insensitive)."
  (find-if (lambda (c)
             (and (listp c)
                  (eq (car c) :element)
                  (string-equal local-name (xml-local c))))
           (xml-children node)))

(defun xml-text (node)
  "Return the concatenated text content of a node's children."
  (with-output-to-string (s)
    (dolist (c (xml-children node))
      (when (and (listp c) (eq (car c) :text))
        (write-string (cadr c) s)))))

(defun xml-attr (name node)
  "Find an attribute value by name."
  (let ((a (find-if (lambda (a) (string-equal name (cadr a)))
                    (xml-attrs node))))
    (when a (caddr a))))

;;; ── SOAP parsing ─────────────────────────────────────────────────────────

(defparameter *soap-ns*
  "http://schemas.xmlsoap.org/soap/envelope/")

(defparameter *calc-ns*
  "http://example.com/soap/calculator/")

(defun soap-body (envelope)
  "Extract the soap:Body element from a parsed envelope."
  (xml-find-child "Body" envelope))

(defun soap-operation (body)
  "Return the first child element of soap:Body -- the operation element."
  (find-if (lambda (c)
             (and (listp c) (eq (car c) :element)))
           (xml-children body)))

(defun soap-param (name op)
  "Extract a named parameter's text value from the operation element."
  (let ((child (xml-find-child name op)))
    (when child
      (string-trim* (xml-text child)))))

;;; ── SOAP envelope builders ───────────────────────────────────────────────

(defun soap-response-envelope (body-content)
  (format nil
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>~%~
     <soap:Envelope~%~
         xmlns:soap=\"http://schemas.xmlsoap.org/soap/envelope/\"~%~
         xmlns:cal=\"http://example.com/soap/calculator/\">~%~
       <soap:Body>~%~
     ~A~
       </soap:Body>~%~
     </soap:Envelope>~%"
    body-content))

(defun soap-result (op-name result-name value)
  (format nil
    "    <cal:~AResponse>~%~
           <cal:~A>~A</cal:~A>~%~
         </cal:~AResponse>~%"
    op-name result-name value result-name op-name))

(defun soap-fault (code reason detail)
  (format nil
    "    <soap:Fault>~%~
           <faultcode>soap:~A</faultcode>~%~
           <faultstring>~A</faultstring>~%~
           <detail>~A</detail>~%~
         </soap:Fault>~%"
    code reason detail))

;;; ── Calculator operations ────────────────────────────────────────────────

(defun dispatch-operation (operation)
  "Dispatch the SOAP operation. Returns (values body-content is-fault)."
  (let ((op-name (xml-local operation)))
    (cond
      ;; Operations requiring two integer params
      ((member op-name '("Add" "Subtract" "Multiply" "Divide")
               :test #'string-equal)
       (let* ((a-str (soap-param "intA" operation))
              (b-str (soap-param "intB" operation))
              (a (when a-str (ignore-errors (parse-integer a-str))))
              (b (when b-str (ignore-errors (parse-integer b-str)))))
         (unless (and a b)
           (return-from dispatch-operation
             (values (soap-fault "Client"
                                 "Invalid parameters"
                                 "intA and intB must be integers")
                     t)))
         (cond
           ((string-equal op-name "Add")
            (values (soap-result "Add" "AddResult" (+ a b)) nil))
           ((string-equal op-name "Subtract")
            (values (soap-result "Subtract" "SubtractResult" (- a b)) nil))
           ((string-equal op-name "Multiply")
            (values (soap-result "Multiply" "MultiplyResult" (* a b)) nil))
           ((string-equal op-name "Divide")
            (if (zerop b)
                (values (soap-fault "Client"
                                    "Division by zero"
                                    "intB must be non-zero")
                        t)
                (values (soap-result "Divide" "DivideResult" (floor a b))
                        nil))))))
      (t
       (values (soap-fault "Client"
                           (format nil "Unknown operation: ~A" op-name)
                           (format nil "Supported: Add Subtract Multiply Divide"))
               t)))))

;;; ── Email reply ──────────────────────────────────────────────────────────

(defun send-reply (to subject in-reply-to soap-envelope-string)
  (let ((sendmail (getenv "MLISP_SENDMAIL" "/usr/sbin/sendmail"))
        (from     (getenv "SOAP_SERVICE_ADDRESS" "soap-calc@example.com")))
    (let ((proc (sb-ext:run-program sendmail (list "-t")
                                    :input :stream
                                    :wait nil)))
      (let ((in (sb-ext:process-input proc)))
        (format in "From: ~A~%" from)
        (format in "To: ~A~%" to)
        (format in "Subject: Re: ~A~%" subject)
        (when in-reply-to
          (format in "In-Reply-To: ~A~%" in-reply-to)
          (format in "References: ~A~%" in-reply-to))
        (format in "Content-Type: text/xml; charset=utf-8~%")
        (format in "~%")
        (write-string soap-envelope-string in)
        (close in))
      (sb-ext:process-wait proc))))

;;; ── Error reply ──────────────────────────────────────────────────────────

(defun send-error-reply (to subject in-reply-to message)
  "Send a plain-text error reply when the request cannot be parsed as SOAP."
  (let ((sendmail (getenv "MLISP_SENDMAIL" "/usr/sbin/sendmail"))
        (from     (getenv "SOAP_SERVICE_ADDRESS" "soap-calc@example.com")))
    (let ((proc (sb-ext:run-program sendmail (list "-t")
                                    :input :stream
                                    :wait nil)))
      (let ((in (sb-ext:process-input proc)))
        (format in "From: ~A~%" from)
        (format in "To: ~A~%" to)
        (format in "Subject: Re: ~A~%" subject)
        (when in-reply-to
          (format in "In-Reply-To: ~A~%" in-reply-to)
          (format in "References: ~A~%" in-reply-to))
        (format in "Content-Type: text/plain; charset=utf-8~%")
        (format in "~%")
        (format in "~A~%~%" message)
        (format in "Namespace: http://example.com/soap/calculator/~%")
        (format in "Operations: Add Subtract Multiply Divide~%")
        (format in "~%")
        (format in "Example request body:~%")
        (format in "~%")
        (format in "<?xml version=\"1.0\" encoding=\"utf-8\"?>~%")
        (format in "<soap:Envelope~%")
        (format in "    xmlns:soap=\"http://schemas.xmlsoap.org/soap/envelope/\"~%")
        (format in "    xmlns:cal=\"http://example.com/soap/calculator/\">~%")
        (format in "  <soap:Body>~%")
        (format in "    <cal:Add>~%")
        (format in "      <cal:intA>3</cal:intA>~%")
        (format in "      <cal:intB>4</cal:intB>~%")
        (format in "    </cal:Add>~%")
        (format in "  </soap:Body>~%")
        (format in "</soap:Envelope>~%")
        (close in))
      (sb-ext:process-wait proc))))

;;; ── Main entry point ─────────────────────────────────────────────────────

(defun main ()
  (let* ((raw (with-output-to-string (s)
                (loop for line = (read-line *standard-input* nil nil)
                      while line
                      do (write-string line s)
                         (write-char #\Newline s)))))
    (multiple-value-bind (headers body)
        (parse-email raw)
      (let ((from       (header "From" headers))
            (subject    (or (header "Subject" headers) ""))
            (message-id (header "Message-ID" headers)))
        (unless from
          ;; No From: -- nothing to reply to, exit silently.
          (sb-ext:exit :code 0))
        (let ((envelope (ignore-errors (parse-xml (string-trim* body)))))
          (unless (and envelope
                       (listp envelope)
                       (string-equal "Envelope" (xml-local envelope)))
            (send-error-reply from subject message-id
                              "Error: message body is not a valid SOAP Envelope.")
            (sb-ext:exit :code 0))
          (let ((body-el (soap-body envelope)))
            (unless body-el
              (send-error-reply from subject message-id
                                "Error: SOAP Envelope has no Body element.")
              (sb-ext:exit :code 0))
            (let ((operation (soap-operation body-el)))
              (unless operation
                (send-error-reply from subject message-id
                                  "Error: SOAP Body contains no operation element.")
                (sb-ext:exit :code 0))
              (multiple-value-bind (body-content is-fault)
                  (dispatch-operation operation)
                (declare (ignore is-fault))
                (let ((response (soap-response-envelope body-content)))
                  (send-reply from subject message-id response))))))))))

(main)
