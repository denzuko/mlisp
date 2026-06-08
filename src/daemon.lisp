;;;; src/daemon.lisp — System daemon address discrimination
;;;;
;;;; Detects auto-generated messages (mailer daemons, vacation programs,
;;;; auto-responders) and drops them silently before any list processing.
;;;; Implements RFC 3834 (auto-submitted), null reverse path, Precedence checks.

(in-package #:mlisp)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Daemon detection predicates
;;; ─────────────────────────────────────────────────────────────────────────────

(defparameter *daemon-from-patterns*
  '("mailer-daemon" "mail-daemon" "mailer_daemon"
    "postmaster" "double-bounce" "mail-delivery"
    "delivery-status" "maildelivery")
  "Case-insensitive substrings in From/Sender that indicate a daemon sender.")

(defparameter *daemon-precedence-values*
  '("junk" "bulk")
  "Precedence: header values that indicate auto-generated mail.
   Note: 'list' is NOT in this list — that is our own header.")

(defun daemon-from-p (headers)
  "Return T if the From or Sender address matches a daemon pattern."
  (let ((from (string-downcase
               (or (extract-address (header-value headers "From"))
                   (header-value headers "From")
                   ""))))
    (some (lambda (pat) (search pat from)) *daemon-from-patterns*)))

(defun null-return-path-p (headers)
  "Return T if Return-Path is explicitly <> (null reverse path — RFC 5321 §4.5.5).
   An absent Return-Path header is NOT treated as null."
  (let ((rp (header-value headers "Return-Path")))
    (when rp
      (string= (string-trim '(#\Space #\Tab) rp) "<>"))))

(defun auto-submitted-p (headers)
  "Return T if Auto-Submitted header is present and not 'no' (RFC 3834)."
  (let ((as (string-downcase
             (or (header-value headers "Auto-Submitted") "no"))))
    (not (or (string= as "no") (string= as "")))))

(defun daemon-precedence-p (headers)
  "Return T if Precedence: indicates junk or bulk auto-generated mail."
  (let ((prec (string-downcase
               (string-trim '(#\Space #\Tab)
                             (or (header-value headers "Precedence") "")))))
    (member prec *daemon-precedence-values* :test #'string=)))

(defun x-auto-response-suppress-p (headers)
  "Return T if X-Auto-Response-Suppress header present (Exchange/Outlook)."
  (not (null (header-value headers "X-Auto-Response-Suppress"))))

(defun daemon-message-p (headers)
  "Return T if the message should be silently dropped as daemon-generated.
   Checks: null Return-Path, daemon From patterns, Auto-Submitted,
   Precedence junk/bulk, X-Auto-Response-Suppress."
  (or (null-return-path-p headers)
      (daemon-from-p headers)
      (auto-submitted-p headers)
      (daemon-precedence-p headers)
      (x-auto-response-suppress-p headers)))

(defun daemon-drop-reason (headers)
  "Return a string describing why the message was identified as daemon mail."
  (cond
    ((null-return-path-p headers)         "null-return-path")
    ((daemon-from-p headers)              "daemon-from-address")
    ((auto-submitted-p headers)           "auto-submitted")
    ((daemon-precedence-p headers)        "precedence-junk-bulk")
    ((x-auto-response-suppress-p headers) "x-auto-response-suppress")
    (t "unknown")))
