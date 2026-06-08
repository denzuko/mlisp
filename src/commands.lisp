;;;; src/commands.lisp — Administrative command detection (subscribe/unsubscribe/help)

(in-package #:mlisp)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Command detection (Subject / body first line)
;;; ─────────────────────────────────────────────────────────────────────────────

(defparameter *known-commands* '("subscribe" "unsubscribe" "help")
  "Administrative command keywords.")

(defun detect-command (headers body-lines)
  "Return one of :SUBSCRIBE :UNSUBSCRIBE :HELP or NIL for regular posts."
  (let* ((subject (string-downcase (or (header-value headers "Subject") "")))
         (first-body (string-downcase (or (first body-lines) "")))
         (probe (lambda (s cmd) (search cmd s))))
    (cond
      ((or (funcall probe subject "subscribe")
           (funcall probe first-body "subscribe"))
       (if (or (funcall probe subject "unsubscribe")
               (funcall probe first-body "unsubscribe"))
           :unsubscribe
           :subscribe))
      ((or (funcall probe subject "unsubscribe")
           (funcall probe first-body "unsubscribe"))
       :unsubscribe)
      ((or (funcall probe subject "help")
           (funcall probe first-body "help"))
       :help)
      (t nil))))
