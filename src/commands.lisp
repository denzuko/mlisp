;;;; src/commands.lisp — Administrative command detection (subscribe/unsubscribe/help)

(in-package #:mlisp)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Command detection (Subject / body first line)
;;; ─────────────────────────────────────────────────────────────────────────────

(defparameter *known-commands* '("subscribe" "unsubscribe" "help" "nomail" "mail" "resume")
  "Administrative command keywords.")

;;; Unsubscribe synonym patterns (smartlist-compatible)
(defparameter *unsubscribe-synonyms*
  '("unsubscribe" "remove me" "remove" "signoff" "sign-off" "opt-out" "optout")
  "Subject/body patterns that trigger unsubscribe.")

(defun matches-any (str patterns)
  "Return T if STR contains any of PATTERNS (case-insensitive)."
  (some (lambda (p) (search p (string-downcase str))) patterns))

(defun detect-command (headers body-lines)
  "Return :SUBSCRIBE :UNSUBSCRIBE :HELP or NIL.
   Recognises smartlist-compatible unsubscribe synonyms."
  (let* ((subject    (or (header-value headers "Subject") ""))
         (first-body (or (first body-lines) ""))
         (unsub-p    (lambda (s)
                       (matches-any s *unsubscribe-synonyms*)))
         (sub-p      (lambda (s)
                       (and (search "subscribe" (string-downcase s))
                            (not (funcall unsub-p s))))))
    (let* ((subj-lc       (string-downcase (or subject "")))
           (first-body-lc (string-downcase (or first-body ""))))
    (cond
      ;; ASK — must come first: "ask how do I subscribe" should route to :ask
      ;; not fall through to :subscribe or :unsubscribe patterns
      ((or (search "ask " subj-lc) (search "ask " first-body-lc)
           (string= subj-lc "ask") (string= first-body-lc "ask"))
       :ask)
      ((or (funcall unsub-p subject)
           (funcall unsub-p first-body))
       :unsubscribe)
      ((or (funcall sub-p subject)
           (funcall sub-p first-body))
       :subscribe)
      ((or (search "help" (string-downcase subject))
           (search "help" (string-downcase first-body)))
       :help)
      ((or (string= (string-downcase subject) "nomail")
           (string= (string-downcase first-body) "nomail"))
       :nomail)
      ((or (member (string-downcase subject) '("mail" "resume") :test #'string=)
           (member (string-downcase first-body) '("mail" "resume") :test #'string=))
       :resume)
      ;; Confirm token (double opt-in)
      ((or (search "confirm " (string-downcase subject))
           (search "confirm " (string-downcase first-body)))
       :confirm)
      ;; Diagnose (list health report)
      ((or (string= subj-lc "diagnose")
           (string= first-body-lc "diagnose"))
       :diagnose)
      ;; INFO — list description and rules (Mailman/LISTSERV)
      ((or (string= subj-lc "info") (string= first-body-lc "info"))
       :info)
      ;; WHO — subscriber list (LISTSERV 'review')
      ((or (search "who" subj-lc) (search "who" first-body-lc))
       :who)
      ;; QUERY — subscriber checks own settings
      ((or (search "query" subj-lc) (search "query" first-body-lc))
       :query)
      ;; SET — subscriber self-service delivery mode
      ((or (search "set " subj-lc) (search "set " first-body-lc))
       :set-delivery)
      ;; SEARCH — search Maildir archive (BITNET/LISTSERV database command)
      ((or (search "search " subj-lc) (search "search " first-body-lc))
       :search)
      ;; INDEX — list archived messages
      ((or (string= subj-lc "index") (search "index " subj-lc)
           (string= first-body-lc "index") (search "index " first-body-lc))
       :index)
      ;; GET — retrieve specific archived message
      ((or (search "get " subj-lc) (search "get " first-body-lc))
       :get-archive)
      ;; FILES — AllFix-style file area listing
      ((or (string= subj-lc "files") (string= first-body-lc "files"))
       :file-index)
      (t nil)))))
