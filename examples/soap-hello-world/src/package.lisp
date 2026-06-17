;;;; src/package.lisp -- package definition for soap-service
;;;;
;;;; Depends on cl-mime for RFC 2045/5322 parsing:
;;;;   mime:parse-headers stream -> alist of (:KEYWORD . "value")
;;;;   mime:parse-mime    string -> MIME object
;;;;   mime:content-type, mime:content-subtype, mime:content
;;;;
;;;; src/rfc5322.lisp is removed -- cl-mime handles headers and body.

(defpackage #:soap-service
  (:use #:cl #:xmls)
  (:export
   ;; Loop guard (operates on cl-mime header alist)
   #:x-loop-p
   ;; List detection (RFC 2369 / 2919, cl-mime header alist)
   #:list-message-p
   ;; Reply routing
   #:reply-to-address
   ;; Content-type (cl-mime content-type/subtype)
   #:soap-content-type-p
   ;; SOAP parsing
   #:parse-soap-envelope
   #:soap-operation-name
   #:soap-param
   ;; SOAP building
   #:build-soap-envelope
   #:build-result
   #:build-fault
   ;; Dispatch
   #:dispatch-soap
   ;; Maildir
   #:maildir-new
   #:mark-read
   ;; Reply
   #:send-reply
   ;; Main
   #:main))
