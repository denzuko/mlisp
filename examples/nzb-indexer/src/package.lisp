;;;; src/package.lisp -- package definition for com.dwightaspencer.nzb-indexer

(defpackage #:com.dwightaspencer.nzb-indexer
  (:use #:cl)
  (:nicknames #:nzb-indexer)
  (:export
   ;; Subject parsing
   #:parse-distrib-subject
   #:release-title-from-filename
   ;; Release index
   #:make-index
   #:find-release
   #:add-segment
   #:release-segment-count
   #:release-complete-p
   #:save-index
   #:load-index
   ;; NZB generation
   #:build-nzb
   ;; Command routing
   #:distrib-message-p
   #:get-nzb-command-p
   #:extract-nzb-title
   #:x-loop-p
   ;; Announce
   #:build-announce-body
   ;; Maildir
   #:maildir-new
   #:mark-read
   ;; Main
   #:main))
