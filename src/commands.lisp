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
    (cond
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
      ((or (string= (string-downcase subject) "diagnose")
           (string= (string-downcase first-body) "diagnose"))
       :diagnose)
      (t nil))))
