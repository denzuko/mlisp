;;;; src/routing.lisp -- email routing logic for soap-service
;;;;
;;;; All functions operate on cl-mime's header alist format:
;;;;   (mime:parse-headers stream) -> ((:FROM . "a@b.com") (:X-LOOP . "...") ...)
;;;;
;;;; x-loop-p        -- loop guard (skip own replies)
;;;; list-message-p  -- RFC 2369/2919 mailing list detection
;;;; reply-to-address -- W3C SOAP 1.2 Email Binding §4.2.3 reply routing

(in-package #:soap-service)

;;; ── X-Loop: guard ────────────────────────────────────────────────────────

(defun x-loop-p (headers service-address)
  "Return T if X-Loop: in HEADERS matches SERVICE-ADDRESS.
   Prevents reprocessing our own replies when fetchmail delivers them
   back into $MAILDIR/new/ after we reply to a list."
  (let ((val (cdr (assoc :x-loop headers))))
    (and val (string-equal (string-trim '(#\Space #\Tab) val)
                            service-address))))

;;; ── Mailing list detection (RFC 2369 / RFC 2919) ─────────────────────────

(defun list-message-p (headers)
  "Return T if HEADERS indicate the message arrived via a mailing list.
   Checks RFC 2919 (List-Id:), RFC 2369 (List-Post:, List-Help:,
   List-Archive:), and MTA conventions (Mailing-List:, Precedence:)."
  (or (assoc :list-id      headers)
      (assoc :list-post    headers)
      (assoc :list-help    headers)
      (assoc :list-archive headers)
      (assoc :mailing-list headers)
      (let ((prec (cdr (assoc :precedence headers))))
        (and prec (member (string-downcase (string-trim '(#\Space #\Tab) prec))
                          '("list" "bulk")
                          :test #'string=)))))

(defun extract-mailto (str)
  "Extract address from 'List-Post: <mailto:addr>' syntax.
   Falls back to trimming and returning the string as-is."
  (let* ((lt  (position #\< str))
         (gt  (when lt (position #\> str :start lt)))
         (inner (if (and lt gt)
                    (subseq str (1+ lt) gt)
                    str)))
    (let ((trimmed (string-trim '(#\Space #\Tab) inner)))
      (if (and (>= (length trimmed) 7)
               (string-equal "mailto:" trimmed :end2 7))
          (subseq trimmed 7)
          trimmed))))

;;; ── Reply address discovery (W3C SOAP 1.2 Email Binding §4.2.3) ──────────

(defun reply-to-address (headers)
  "Discover the correct reply address per W3C SOAP 1.2 Email Binding.

   When the message arrived via a mailing list (RFC 2369/2919 headers
   or Precedence:), the list address is the transport endpoint -- all
   subscribers (including downstream SOAP consumers) receive the reply:
     mode :list   -> List-Post: address (or To: as fallback)

   Without list headers, reply directly to the original sender:
     mode :direct -> From: address

   Returns (values address mode) where mode is :list or :direct."
  (if (list-message-p headers)
      (let ((list-post (cdr (assoc :list-post headers))))
        (values
         (if list-post
             (extract-mailto list-post)
             (cdr (assoc :to headers)))
         :list))
      (values (cdr (assoc :from headers)) :direct)))
