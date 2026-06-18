;;;; src/routing.lisp -- email routing logic for soap-service
;;;;
;;;; All functions operate on cl-mime's header alist format:
;;;;   (mime:parse-headers stream) -> ((:FROM . "a@b.com") (:X-LOOP . "...") ...)
;;;;
;;;; x-loop-p        -- loop guard (skip own replies)
;;;; list-message-p  -- RFC 2369/2919 mailing list detection
;;;; reply-to-address -- W3C SOAP 1.2 Email Binding §4.2.3 reply routing

(in-package #:com.dwightaspencer.soap-example)

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

;;; ── Email security header inspection ────────────────────────────────────
;;; These functions check the Authentication-Results header (RFC 7601)
;;; and related security headers set by the MTA/MDA stack.
;;;
;;; IMPORTANT SCOPE NOTE: mlisp's MTA/MDA ecosystem (Postfix, procmail,
;;; fetchmail, DKIM milters, SPF policy daemons, DMARC reporters, MTA-STS
;;; policy enforcement, DNSSEC resolver) performs the actual cryptographic
;;; verification and policy enforcement BEFORE messages reach $MAILDIR/.
;;; These functions READ and CHECK the results they recorded in headers --
;;; they do not re-implement or replace that infrastructure.
;;;
;;; The security posture is: trust the MTA stack's verdict (it has the
;;; keys, the DNS resolver, the TLS session context), surface that verdict
;;; for routing decisions and audit logging at the application layer.
;;;
;;; GPG/S-MIME message signing is deliberately out of scope for this
;;; library -- handle it at the MDA layer (procmail + gpg) before
;;; delivery to $MAILDIR/ if required by the deployment.


(defun parse-auth-results-field (value)
  "Parse an Authentication-Results header value into an alist of
   (method . result) pairs. Handles RFC 7601 format:
     'mx.example.com; dkim=pass header.d=example.com; spf=pass'
   Returns e.g. ((\"dkim\" . \"pass\") (\"spf\" . \"pass\") ...)."
  (let ((results '()))
    (dolist (part (cdr (split-by-semicolon (or value ""))))
      (let* ((trimmed (string-trim '(#\Space #\Tab) part))
             (eq-pos  (position #\= trimmed)))
        (when eq-pos
          (let* ((method (string-trim '(#\Space #\Tab) (subseq trimmed 0 eq-pos)))
                 (rest   (subseq trimmed (1+ eq-pos)))
                 (result (string-trim '(#\Space #\Tab)
                                      (subseq rest 0 (or (position #\Space rest)
                                                          (length rest))))))
            (push (cons method result) results)))))
    (nreverse results)))

(defun split-by-semicolon (str)
  (let ((parts '()) (start 0))
    (loop for i from 0 below (length str) do
      (when (char= (char str i) #\;)
        (push (subseq str start i) parts)
        (setf start (1+ i))))
    (push (subseq str start) parts)
    (nreverse parts)))

(defun authentication-results-p (headers)
  "Return T if an Authentication-Results header is present (RFC 7601).
   Presence means the message passed through an MTA that performed
   authentication checks."
  (not (null (assoc :authentication-results headers))))

(defun check-authentication-results (headers)
  "Parse Authentication-Results header into an alist.
   Returns nil if no Authentication-Results header is present."
  (let ((val (cdr (assoc :authentication-results headers))))
    (when val (parse-auth-results-field val))))

(defun auth-method-pass-p (method headers)
  "Return T if METHOD (e.g. \"dkim\", \"spf\", \"dmarc\", \"arc\")
   reports 'pass' in the Authentication-Results header."
  (let ((results (check-authentication-results headers)))
    (let ((entry (assoc method results :test #'string-equal)))
      (and entry (string-equal "pass" (cdr entry))))))

(defun dkim-pass-p (headers)
  "Return T if DKIM signature verification passed (Authentication-Results)."
  (auth-method-pass-p "dkim" headers))

(defun spf-pass-p (headers)
  "Return T if SPF check passed (Authentication-Results or Received-SPF)."
  (or (auth-method-pass-p "spf" headers)
      ;; Some MTAs write Received-SPF: instead of/in addition to Auth-Results
      (let ((spf (cdr (assoc :received-spf headers))))
        (and spf (string-equal "pass"
                                (string-trim '(#\Space #\Tab)
                                             (subseq spf 0 (min 4 (length spf)))))))))

(defun dmarc-pass-p (headers)
  "Return T if DMARC policy check passed (Authentication-Results)."
  (auth-method-pass-p "dmarc" headers))
