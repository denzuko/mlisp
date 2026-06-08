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
   ;; Compliance
   #:tag-subject
   #:compliance-footer-text))
