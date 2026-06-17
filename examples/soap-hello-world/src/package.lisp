;;;; src/package.lisp -- package definition for soap-service

(defpackage #:soap-service
  (:use #:cl #:xmls)
  (:export
   ;; RFC 5322
   #:parse-message
   #:header
   ;; Loop guard
   #:x-loop-p
   ;; List detection (RFC 2369 / 2919)
   #:list-message-p
   ;; Reply routing
   #:reply-to-address
   ;; Content-type
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
