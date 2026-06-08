;;;; src/package.lisp — Package definition for mlisp

(defpackage #:mlisp
  (:use #:cl)
  (:export
   ;; Entry point
   #:main
   ;; State I/O
   #:load-state
   #:save-state
   ;; Core pipeline
   #:process-message
   ;; State accessors (exported for mlisp-test)
   #:find-list
   #:list-subscribers
   #:subscriber-addresses
   #:subscriber-p
   #:add-subscriber
   #:remove-subscriber
   #:list-drop-address
   #:list-loop-header
   #:list-postal-address
   #:list-privacy-url
   #:iso8601-now
   ;; Parser
   #:parse-headers
   #:read-message-from-stdin
   #:header-value
   #:extract-address
   ;; Commands
   #:detect-command
   ;; Troff DSL
   #:sexp->troff
   #:render-troff-to-text
   #:render-template
   ;; MIME inbound processor
   #:strip-html
   #:decode-html-entities
   #:extract-mime-boundary
   #:classify-content-type
   #:mime-extract-text
   #:process-body-for-distribution
   ;; Compliance
   #:tag-subject
   #:compliance-footer-text
   ;; Audit log (used by mlisp-admin)
   #:audit-append
   #:audit-path
   ;; Internal state (mlisp-admin needs direct access)
   #:*state*
   ;; Path resolution (used by mlisp-admin)
   #:mlisp-home
   #:*mlisp-home-override*
   #:state-path
   #:audit-path
   #:template-dir
   #:sendmail-path
   ;; Arg parsing (used by mlisp-admin)
   #:parse-common-flags))
