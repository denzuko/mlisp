;;;; src/package.lisp -- package definition for com.dwightaspencer.soap-example
;;;;
;;;; Package hierarchy matches system hierarchy:
;;;;   com.dwightaspencer.soap-example  -- the single runtime package
;;;;     (all systems share one package; the system split is for dependency
;;;;      management and publication boundaries, not runtime namespacing)
;;;;
;;;; Depends on cl-mime for RFC 2045/5322 parsing:
;;;;   mime:parse-headers stream -> (:KEYWORD . "value") alist
;;;;   mime:parse-mime    string -> MIME object
;;;;   mime:content-type, mime:content-subtype, mime:content

(defpackage #:com.dwightaspencer.soap-example
  (:use #:cl #:xmls)
  (:nicknames #:soap-example)           ; short alias for interactive use
  (:export
   ;; ── Transport layer: com.dwightaspencer.soap-example/soap12-email ────
   ;;
   ;; Email security header inspection (RFC 7601, DKIM, SPF, DMARC)
   #:check-authentication-results      ; parse Authentication-Results
   #:dkim-pass-p                       ; DKIM signature verified?
   #:spf-pass-p                        ; SPF check passed?
   #:dmarc-pass-p                      ; DMARC policy passed?
   #:authentication-results-p          ; any auth header present?
   ;;
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
   ;;
   ;; ── Service layer: com.dwightaspencer.soap-example/service ───────────
   ;; Calculator example -- implements the handler protocol
   ;; (replace dispatch-soap + calc-envelope for your own service)
   #:dispatch-soap
   #:*calc-ns*
   #:*calc-prefix*
   #:calc-envelope
   ;; Entry point (wired to calculator defaults)
   #:main))

;;; Backward-compatible alias for systems that loaded the old "soap-service" name
(defpackage #:soap-service
  (:use)
  (:nicknames #:soap-service))
