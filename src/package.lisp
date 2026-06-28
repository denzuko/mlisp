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
   #:substitute-tokens
   #:substitute-sexp-tokens
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
   ;; MTA (used by mlisp-admin approve and distrib)
   #:sendmail
   #:handle-welcome
   #:distribute-message
   #:rfc2369-headers
   #:compliance-footer-text
   ;; Audit log (used by mlisp-admin)
   #:audit-append
   ;; Metrics
   #:write-metrics-file
   #:record-metric
   #:metrics-path
   #:*metric-events*
   ;; Bounce management
   #:process-bounce
   #:dsn-p
   #:extract-final-recipients
   #:increment-bounce
   #:clear-bounce
   #:subscriber-bounce-count
   ;; State accessors - new fields
   #:list-request-address
   #:list-auto-subscribe-p
   #:list-max-bounces
   ;; GPG and hash-at-rest
   #:sha256-hex
   #:address-hash
   #:list-hash-contacts-p
   #:subscriber-p-hashed
   #:add-subscriber-hashed
   #:remove-subscriber-hashed
   #:gpg-signed-p
   #:gpg-encrypted-p
   #:list-require-signed-p
   #:list-gpg-key-id
   #:gpg-verify
   ;; Double opt-in confirmation
   #:confirm-subscribe-p
   #:add-pending
   #:validate-token
   #:consume-token
   #:pending-entries
   #:clear-expired-pending
   #:send-subscribe-challenge
   #:extract-confirm-token
   ;; Plugin filters
   #:invoke-filter-chain
   #:invoke-single-filter
   #:pipe-through-command
   ;; AllFix/distrib
   #:add-file-to-distrib
   ;; mlisp-bugs (#69)
   #:bugs-packages
   #:find-bugs-package
   #:add-bugs-package
   #:bugs-package-counter
   #:bugs-next-id
   #:bugs-derive-state
   #:bugs-list-open
   #:bugs-list-closed
   #:bug-exists-p
   #:bugs-list-id
   #:bugs-archive
   #:bugs-generate-report
   #:bugs-process-submit
   #:bugs-process-append
   #:bugs-set-option
   #:bugs-invoke-filter
   #:bugs-process-close
   #:bugs-process-control
   ;; procmail-gen DSL
   #:recipe->procmailrc
   #:recipe-set->procmailrc
   #:procmailrc-has-marker-p
   #:read-recipes-from-file
   #:write-procmail-recipes
   #:list-recipes
   #:bugs-recipes
   #:parse-pseudo-headers
   #:parse-control-body
   #:inject-pseudo-headers
   #:distrib-archive-path
   ;; Request handlers
   #:handle-info-command
   #:handle-who-command
   #:handle-query-command
   #:handle-set-delivery-command
   #:handle-search-command
   #:handle-index-command
   #:handle-get-archive-command
   #:handle-file-index-command
   #:handle-ask-command
   #:cl-tokenize
   #:extract-list-arg
   ;; Rate limiting
   #:rate-limit-exceeded-p
   ;; Embargo
   #:embargoed-p
   #:list-embargoed-until
   ;; Subgroup predicates (new)
   #:list-owner-subgroup-p
   #:list-security-p
   #:list-commits-p
   #:list-bot-address
   #:list-owner-addresses
   ;; VERP
   #:verp-encode
   #:verp-decode
   #:list-verp-p
   ;; NOMAIL, locking
   #:subscriber-nomail-p
   #:set-subscriber-nomail
   #:find-subscriber
   ;; Namespace-subgroup model
   #:list-subgroup
   #:list-namespace
   #:namespace-siblings
   #:list-announce-p
   #:list-owner-address
   #:owner-post-p
   #:*known-subgroups*
   ;; Diagnosis and multigram bounce
   #:collect-diagnosis
   #:format-diagnosis
   #:handle-diagnose
   #:write-extended-metrics
   #:windowed-increment-bounce
   #:record-delivery-success
   #:maybe-reset-bounce
   #:bounce-hard-p
   ;; Daemon discrimination
   #:daemon-message-p
   #:daemon-drop-reason
   ;; Dedup
   #:duplicate-p
   #:record-dedup
   #:message-id
   #:dedup-entries
   #:clear-dedup-cache
   ;; Maildir
   #:maildir-write
   #:maybe-archive-to-maildir
   ;; Moderation queue
   #:list-moderated-p
   #:hold-message
   #:held-queue
   #:release-held
   #:purge-held
   #:list-digest-mode-p
   #:buffer-for-digest
   #:flush-digest
   ;; Exploder
   #:list-exploder-p
   #:exploder-members
   #:distribute-exploder
   ;; Process mode
   #:*process-mode*
   #:*metrics-path-override*
   #:audit-path
   ;; Internal state (mlisp-admin needs direct access)
   #:*state*
   ;; Path resolution (used by mlisp-admin)
   #:mlisp-home
   #:mlisp-init-target
   #:maildir-root
   #:*mlisp-home-override*
   #:state-path
   #:audit-path
   #:template-dir
   #:sendmail-path
   ;; Arg parsing (used by mlisp-admin)
   #:parse-common-flags))
