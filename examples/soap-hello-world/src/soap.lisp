;;;; src/soap.lisp -- SOAP 1.2 envelope parser and builder
;;;;
;;;; Uses xmls for namespace-aware XML parsing.
;;;; Media type: application/soap+xml per RFC 3902 (REQUIRED by W3C spec).

(in-package #:soap-service)

(defun trim (str)
  (string-trim '(#\Space #\Tab #\Return #\Newline) (or str "")))

;;; ── Constants ────────────────────────────────────────────────────────────

(defparameter +soap-ns+
  "http://schemas.xmlsoap.org/soap/envelope/")

(defparameter +soap-media-type+
  "application/soap+xml")               ; RFC 3902

;;; ── Content-type check (RFC 3902) ───────────────────────────────────────

(defun soap-content-type-p (content-type content-subtype)
  "Return T if content-type/subtype is application/soap+xml (RFC 3902).
   Takes the two values from mime:content-type and mime:content-subtype
   separately, matching how cl-mime exposes them."
  (and content-type
       content-subtype
       (string-equal content-type    "application")
       (string-equal content-subtype "soap+xml")))

;;; ── xmls helpers ─────────────────────────────────────────────────────────

(defun xmls-find-child (local-name ns node)
  "First child of NODE with matching local name and namespace URI."
  (dolist (child (xmls:node-children node))
    (when (and (xmls:node-p child)
               (string-equal local-name (xmls:node-name child))
               (or (null ns) (equal ns (xmls:node-ns child))))
      (return child))))

(defun xmls-child-text (local-name ns node)
  "Text content of the first matching child element."
  (let ((child (xmls-find-child local-name ns node)))
    (when child
      (let ((kids (xmls:node-children child)))
        (when (and kids (stringp (car kids)))
          (trim (car kids)))))))

;;; ── SOAP envelope parsing ────────────────────────────────────────────────

(defun parse-soap-envelope (body-string)
  "Parse BODY-STRING as a SOAP 1.2 envelope using xmls.
   Returns the xmls operation node (first element child of soap:Body).
   Signals an error if the structure is invalid."
  (let ((doc (handler-case (xmls:parse body-string)
               (error (e) (error "XML parse error: ~A" e)))))
    (unless (string-equal "Envelope" (xmls:node-name doc))
      (error "Root element is not soap:Envelope (got ~S)" (xmls:node-name doc)))
    (let ((body (xmls-find-child "Body" +soap-ns+ doc)))
      (unless body
        (error "No soap:Body element found in envelope"))
      (let ((op (find-if #'xmls:node-p (xmls:node-children body))))
        (unless op
          (error "soap:Body is empty -- no operation element"))
        op))))

(defun soap-operation-name (operation)
  "Return the local name of the SOAP operation element."
  (xmls:node-name operation))

(defun soap-param (name operation &optional ns)
  "Return integer value of parameter NAME in OPERATION.
   NS is the namespace URI to match (nil matches any namespace).
   Signals an error if the parameter is absent or not an integer."
  (let ((text (xmls-child-text name ns operation)))
    (unless text
      (error "Missing SOAP parameter: ~A" name))
    (multiple-value-bind (val end)
        (parse-integer text :junk-allowed t)
      (unless (and val (= end (length text)))
        (error "SOAP parameter ~A is not an integer: ~S" name text))
      val)))

;;; ── SOAP envelope builder ────────────────────────────────────────────────

(defun build-soap-envelope (body-content &key (extra-namespaces nil))
  "Wrap BODY-CONTENT in a SOAP 1.2 Envelope.
   EXTRA-NAMESPACES is an alist of (prefix . uri) pairs for service-
   specific namespaces declared on the envelope element, e.g.:
     '((\"cal\" . \"http://example.com/soap/calculator/\"))
   This keeps the envelope builder generic -- callers supply the
   namespace declarations their body content requires."
  (with-output-to-string (s)
    (write-string "<?xml version=\"1.0\" encoding=\"utf-8\"?>" s)
    (terpri s)
    (format s "<env:Envelope~%    xmlns:env=\"~A\"" +soap-ns+)
    (dolist (ns extra-namespaces)
      (format s "~%    xmlns:~A=\"~A\"" (car ns) (cdr ns)))
    (write-string ">" s)
    (terpri s)
    (write-string "  <env:Body>" s)
    (terpri s)
    (write-string body-content s)
    (write-string "  </env:Body>" s)
    (terpri s)
    (write-string "</env:Envelope>" s)
    (terpri s)))

(defun build-result (op-name result-name value &optional (prefix "svc"))
  "Build a SOAP response element. PREFIX is the namespace prefix used
   in the body content (must match what's declared in the envelope)."
  (format nil
    "    <~A:~AResponse>~%      <~A:~A>~A</~A:~A>~%    </~A:~AResponse>~%"
    prefix op-name prefix result-name value prefix result-name prefix op-name))

(defun build-fault (code reason detail)
  "Build a SOAP 1.2 Fault element."
  (format nil
    "    <env:Fault>~%~
           <env:Code><env:Value>env:~A</env:Value></env:Code>~%~
           <env:Reason>~%~
             <env:Text xml:lang=\"en\">~A</env:Text>~%~
           </env:Reason>~%~
           <env:Detail>~A</env:Detail>~%~
         </env:Fault>~%"
    code reason detail))

;;; ── Constants ────────────────────────────────────────────────────────────

(defconstant +soap-ns+
  "http://schemas.xmlsoap.org/soap/envelope/")

(defconstant +calc-ns+
  "http://example.com/soap/calculator/")

(defconstant +soap-media-type+
  "application/soap+xml")               ; RFC 3902

;;; ── Content-type check (RFC 3902) ───────────────────────────────────────

(defun soap-content-type-p (content-type content-subtype)
  "Return T if content-type/subtype is application/soap+xml (RFC 3902).
   Takes the two values from mime:content-type and mime:content-subtype
   separately, matching how cl-mime exposes them."
  (and content-type
       content-subtype
       (string-equal content-type    "application")
       (string-equal content-subtype "soap+xml")))

;;; ── xmls helpers ─────────────────────────────────────────────────────────

(defun xmls-find-child (local-name ns node)
  "First child of NODE with matching local name and namespace URI."
  (dolist (child (xmls:node-children node))
    (when (and (xmls:node-p child)
               (string-equal local-name (xmls:node-name child))
               (or (null ns) (equal ns (xmls:node-ns child))))
      (return child))))

(defun xmls-child-text (local-name ns node)
  "Text content of the first matching child element."
  (let ((child (xmls-find-child local-name ns node)))
    (when child
      (let ((kids (xmls:node-children child)))
        (when (and kids (stringp (car kids)))
          (trim (car kids)))))))

;;; ── SOAP envelope parsing ────────────────────────────────────────────────

(defun parse-soap-envelope (body-string)
  "Parse BODY-STRING as a SOAP 1.2 envelope using xmls.
   Returns the xmls operation node (first element child of Body).
   Signals an error if the structure is invalid."
  (let ((doc (handler-case (xmls:parse body-string)
               (error (e) (error "XML parse error: ~A" e)))))
    (unless (string-equal "Envelope" (xmls:node-name doc))
      (error "Root element is not soap:Envelope (got ~S)" (xmls:node-name doc)))
    (let ((body (xmls-find-child "Body" +soap-ns+ doc)))
      (unless body
        (error "No soap:Body element found in envelope"))
      (let ((op (find-if #'xmls:node-p (xmls:node-children body))))
        (unless op
          (error "soap:Body is empty -- no operation element"))
        op))))

(defun soap-operation-name (operation)
  "Return the local name of the SOAP operation element."
  (xmls:node-name operation))

(defun soap-param (name operation)
  "Return integer value of parameter NAME in OPERATION, or signal error."
  (let ((text (xmls-child-text name +calc-ns+ operation)))
    (unless text
      (error "Missing SOAP parameter: ~A" name))
    (multiple-value-bind (val end)
        (parse-integer text :junk-allowed t)
      (unless (and val (= end (length text)))
        (error "SOAP parameter ~A is not an integer: ~S" name text))
      val)))
