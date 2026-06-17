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
   ;; ── Transport layer (generic, publishable) ───────────────────────────
   ;; Loop guard
   #:x-loop-p
   ;; List detection (RFC 2369 / 2919)
   #:list-message-p
   ;; Reply routing (W3C SOAP 1.2 Email Binding §4.2.3)
   #:reply-to-address
   ;; Content-type (RFC 3902)
   #:soap-content-type-p
   ;; SOAP envelope parsing
   #:parse-soap-envelope
   #:soap-operation-name
   #:soap-param
   ;; SOAP envelope building (namespace-parameterised)
   #:build-soap-envelope
   #:build-result
   #:build-fault
   ;; Maildir batch processing
   #:maildir-new
   #:mark-read
   ;; Sendmail reply
   #:send-reply
   ;; Generic batch processor (inject your own handler + envelope-builder)
   #:process-batch
   ;; ── Example layer (calculator service, not part of generic library) ──
   ;; Dispatcher -- implement this protocol for your own service
   #:dispatch-soap
   ;; Namespace parameters -- owned by the example, not the transport
   #:*calc-ns*
   #:*calc-prefix*
   ;; Convenience envelope wrapper for the calculator namespace
   #:calc-envelope
   ;; Entry point (wired to calculator example defaults)
   #:main))
