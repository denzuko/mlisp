;;;; src/confirm.lisp — Double opt-in subscribe/unsubscribe confirmation
;;;;
;;;; Token lifecycle:
;;;;   1. subscribe command → generate token, store pending, send challenge
;;;;   2. "confirm <token>" reply → validate, complete subscribe, send welcome
;;;;   3. Tokens expire after :confirm-window-hours (default 48)
;;;;
;;;; State: state/pending/<list-id>.sexp
;;;;   Each entry: (:token :address :type :created-at :list-id)

(in-package #:mlisp)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Token storage
;;; ─────────────────────────────────────────────────────────────────────────────

(defun pending-path (list-id)
  (merge-pathnames (format nil "state/pending/~A.sexp" list-id)
                   (mlisp-home)))

(defun load-pending (list-id)
  (let ((path (pending-path list-id)))
    (if (probe-file path)
        (with-open-file (s path) (or (ignore-errors (read s)) '()))
        '())))

(defun save-pending (list-id entries)
  (let* ((path (pending-path list-id))
         (tmp  (format nil "~A.tmp" path)))
    (ensure-directories-exist path)
    (with-open-file (s tmp :direction :output :if-exists :supersede
                           :if-does-not-exist :create)
      (let ((*print-pretty* t) (*print-case* :downcase))
        (write entries :stream s) (terpri s)))
    (rename-file tmp path)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Token generation
;;; ─────────────────────────────────────────────────────────────────────────────

(defun make-confirm-token (list-id address)
  "Generate a 32-char hex confirmation token (first 32 chars of SHA-256)."
  (let ((raw (sha256-hex (format nil "~A|~A|~A" list-id address (get-universal-time)))))
    (subseq raw 0 32)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Pending queue operations
;;; ─────────────────────────────────────────────────────────────────────────────

(defun list-confirm-window (list-id)
  "Return confirmation window in seconds for LIST-ID."
  (* (or (getf (find-list list-id) :confirm-window-hours) 48) 3600))

(defun confirm-subscribe-p (list-id)
  "Return T if LIST-ID requires confirmed subscribe.
   Defaults to T (safe). set-option confirm-subscribe false to disable."
  (let ((flag (getf (find-list list-id) :confirm-subscribe :unset)))
    ;; :unset (key absent) → default T
    ;; nil (explicit false set via set-option) → NIL
    ;; any other value → T
    (not (eq flag nil))))

(defun add-pending (list-id address type)
  "Add a pending confirmation entry. Returns the token."
  (let* ((token   (make-confirm-token list-id address))
         (entries (load-pending list-id))
         ;; Remove any existing pending for same address/type
         (cleaned (remove-if (lambda (e)
                               (and (string-equal (getf e :address) address)
                                    (eq (getf e :type) type)))
                             entries))
         (entry   (list :token token
                        :address address
                        :type type
                        :created-at (get-universal-time)
                        :list-id list-id)))
    (save-pending list-id (cons entry cleaned))
    token))

(defun validate-token (list-id token)
  "Return the pending entry if TOKEN is valid and unexpired, or nil."
  (let* ((entries (load-pending list-id))
         (window  (list-confirm-window list-id))
         (now     (get-universal-time)))
    (find-if (lambda (e)
               (and (string-equal (getf e :token) token)
                    (< (- now (getf e :created-at 0)) window)))
             entries)))

(defun consume-token (list-id token)
  "Remove TOKEN from pending queue. Returns the entry or nil."
  (let* ((entries (load-pending list-id))
         (entry   (find-if (lambda (e) (string-equal (getf e :token) token))
                           entries)))
    (when entry
      (save-pending list-id
                    (remove-if (lambda (e) (string-equal (getf e :token) token))
                               entries)))
    entry))

(defun pending-entries (list-id)
  "Return all current (unexpired) pending entries for LIST-ID."
  (let* ((entries (load-pending list-id))
         (window  (list-confirm-window list-id))
         (now     (get-universal-time)))
    (remove-if (lambda (e)
                 (>= (- now (getf e :created-at 0)) window))
               entries)))

(defun clear-expired-pending (list-id)
  "Remove expired tokens from pending queue. Returns count removed."
  (let* ((all     (load-pending list-id))
         (fresh   (pending-entries list-id))
         (removed (- (length all) (length fresh))))
    (save-pending list-id fresh)
    removed))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Challenge email
;;; ─────────────────────────────────────────────────────────────────────────────

(defun send-subscribe-challenge (list-id address token)
  "Send a confirmation challenge email to ADDRESS."
  (let* ((req-addr (list-request-address list-id))
         (drop     (list-drop-address list-id))
         (body
          (format nil
"You (or someone using your address) requested subscription to ~A.

To confirm, reply to this message with the following in the subject or body:

  confirm ~A

This link expires in ~A hours. If you did not request this, ignore this message.

-- ~A list management"
                  list-id token
                  (/ (list-confirm-window list-id) 3600)
                  list-id)))
    (sendmail (list address) body
              :extra-headers
              (list (cons "Subject"
                          (format nil "Confirm subscription to ~A" list-id))
                    (cons "From" drop)
                    (cons "Reply-To" req-addr)
                    (cons "To" address)))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Confirm command detection
;;; ─────────────────────────────────────────────────────────────────────────────

(defun extract-confirm-token (headers body-lines)
  "Extract a confirmation token from subject or body.
   Token format: 'confirm <32-char-hex>' anywhere in subject or body."
  (let* ((subject   (string-downcase (or (header-value headers "Subject") "")))
         (body-text (string-downcase (or (first body-lines) "")))
         (pattern   "confirm "))
    (dolist (text (list subject body-text))
      (let ((idx (search pattern text)))
        (when idx
          (let* ((start (+ idx (length pattern)))
                 (end   (min (length text) (+ start 64)))
                 (token (string-trim " \t\r\n" (subseq text start end))))
            (when (>= (length token) 16)
              (return-from extract-confirm-token token))))))
    nil))
