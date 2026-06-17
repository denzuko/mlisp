;;;; src/soap.lisp -- SOAP 1.2 envelope parser and builder
;;;;
;;;; Uses xmls for namespace-aware XML parsing.
;;;; Media type: application/soap+xml per RFC 3902 (REQUIRED by W3C spec).

(in-package #:soap-service)

;;; ── Constants ────────────────────────────────────────────────────────────

(defconstant +soap-ns+
  "http://schemas.xmlsoap.org/soap/envelope/")

(defconstant +calc-ns+
  "http://example.com/soap/calculator/")

(defconstant +soap-media-type+
  "application/soap+xml")               ; RFC 3902

;;; ── Content-type check ───────────────────────────────────────────────────

(defun soap-content-type-p (content-type)
  "Return T if CONTENT-TYPE is application/soap+xml (RFC 3902).
   Nil content-type returns nil. Absent Content-Type is handled
   leniently by the caller (try to parse anyway)."
  (and content-type
       (let ((ct (string-downcase (trim content-type))))
         (not (null (search "soap+xml" ct))))))

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

;;; ── SOAP envelope builder ────────────────────────────────────────────────

(defun build-soap-envelope (body-content)
  "Wrap BODY-CONTENT in a SOAP 1.2 Envelope with namespace declarations."
  (format nil
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>~%~
     <env:Envelope~%~
         xmlns:env=\"~A\"~%~
         xmlns:cal=\"~A\">~%~
       <env:Body>~%~A~
       </env:Body>~%~
     </env:Envelope>~%"
    +soap-ns+ +calc-ns+ body-content))

(defun build-result (op-name result-name value)
  "Build a SOAP response element for OP-NAME with RESULT-NAME=VALUE."
  (format nil
    "    <cal:~AResponse>~%      <cal:~A>~A</cal:~A>~%    </cal:~AResponse>~%"
    op-name result-name value result-name op-name))

(defun build-fault (code reason detail)
  "Build a SOAP 1.2 Fault element per §5.4 of the SOAP spec."
  (format nil
    "    <env:Fault>~%~
           <env:Code><env:Value>env:~A</env:Value></env:Code>~%~
           <env:Reason>~%~
             <env:Text xml:lang=\"en\">~A</env:Text>~%~
           </env:Reason>~%~
           <env:Detail>~A</env:Detail>~%~
         </env:Fault>~%"
    code reason detail))
