;;;; src/rfc5322.lisp -- RFC 5322 internet message parser
;;;;
;;;; Implements:
;;;;   parse-message  -- split raw message into headers alist + body string
;;;;   header         -- case-insensitive header lookup
;;;;   x-loop-p       -- X-Loop: guard (loop detection)
;;;;   list-message-p -- RFC 2369/2919 mailing list detection
;;;;   reply-to-address -- W3C SOAP 1.2 Email Binding reply routing

(in-package #:soap-service)

;;; ── String utilities ─────────────────────────────────────────────────────

(defun trim (str)
  (string-trim '(#\Space #\Tab #\Return #\Newline) (or str "")))

(defun split-lines (str)
  "Split on CRLF or bare LF; return list of line strings."
  (let ((lines '()) (start 0) (len (length str)))
    (loop for i from 0 below len do
      (when (char= (char str i) #\Newline)
        (let ((end (if (and (> i 0) (char= (char str (1- i)) #\Return))
                       (1- i) i)))
          (push (subseq str start end) lines)
          (setf start (1+ i)))))
    (when (< start len)
      (push (subseq str start) lines))
    (nreverse lines)))

;;; ── RFC 5322 parser ──────────────────────────────────────────────────────

(defun parse-message (raw)
  "Parse RFC 5322 message into (values headers body).
   Headers: alist of (name . value). Folded headers are unfolded.
   Body: string after the first blank line."
  (let ((lines    (split-lines raw))
        (headers  '())
        (body-acc '())
        (in-body  nil))
    (dolist (line lines)
      (cond
        (in-body
         (push line body-acc))
        ;; Blank line → start of body
        ((zerop (length (trim line)))
         (setf in-body t))
        ;; Folded continuation (RFC 5322 §2.2.3)
        ((and (> (length line) 0)
              (member (char line 0) '(#\Space #\Tab)))
         (when headers
           (setf (cdar headers)
                 (concatenate 'string (cdar headers) " " (trim line)))))
        ;; Header field
        (t
         (let ((colon (position #\: line)))
           (when colon
             (push (cons (trim (subseq line 0 colon))
                         (trim (subseq line (1+ colon))))
                   headers))))))
    (values
     (nreverse headers)
     (with-output-to-string (s)
       (dolist (l (nreverse body-acc))
         (write-string l s)
         (write-char #\Newline s))))))

(defun header (name headers)
  "Case-insensitive header lookup. Returns value string or nil."
  (cdr (assoc name headers :test #'string-equal)))

;;; ── X-Loop: guard ────────────────────────────────────────────────────────

(defun x-loop-p (headers service-address)
  "Return T if X-Loop: matches SERVICE-ADDRESS (our own reply marker).
   Prevents the service reprocessing replies it sent to a list when
   fetchmail pulls them back into $MAILDIR/new/."
  (let ((val (header "X-Loop" headers)))
    (and val (string-equal (trim val) service-address))))

;;; ── Mailing list detection (RFC 2369 / RFC 2919) ─────────────────────────

(defun list-message-p (headers)
  "Return T if the message was delivered via a mailing list.
   Checks RFC 2919 (List-Id:), RFC 2369 (List-Post:, List-Help:,
   List-Archive:), and MTA conventions (Mailing-List:, Precedence:)."
  (or (header "List-Id"      headers)
      (header "List-Post"    headers)
      (header "List-Help"    headers)
      (header "List-Archive" headers)
      (header "Mailing-List" headers)
      (let ((prec (header "Precedence" headers)))
        (and prec (member (string-downcase (trim prec))
                          '("list" "bulk")
                          :test #'string=)))))

(defun extract-mailto (str)
  "Extract address from 'List-Post: <mailto:addr>' or plain 'addr'."
  (let* ((lt  (position #\< str))
         (gt  (when lt (position #\> str :start lt)))
         (inner (if (and lt gt)
                    (subseq str (1+ lt) gt)
                    str)))
    (trim
     (if (string-equal "mailto:" inner :end2 (min 7 (length inner)))
         (subseq inner 7)
         inner))))

;;; ── Reply address discovery (W3C SOAP 1.2 Email Binding §4.2.3) ──────────

(defun reply-to-address (headers)
  "Discover the correct reply address per W3C SOAP 1.2 Email Binding.

   Direct (1:1): sender-node-uri = From: of the request.
   List   (1:many): list address = List-Post: or To: of the request.

   Returns (values address mode) where mode is :list or :direct."
  (if (list-message-p headers)
      (let ((list-post (header "List-Post" headers)))
        (values
         (if list-post
             (extract-mailto list-post)
             (header "To" headers))
         :list))
      (values (header "From" headers) :direct)))
