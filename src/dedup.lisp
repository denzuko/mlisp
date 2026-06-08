;;;; src/dedup.lisp — Duplicate message detection and suppression
;;;;
;;;; Maintains a per-list ring buffer of recent Message-Id values.
;;;; Suppresses duplicate deliveries within the dedup window.
;;;; Cache stored in state/dedup/<list-id>.sexp — separate from main state.

(in-package #:mlisp)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Dedup cache path
;;; ─────────────────────────────────────────────────────────────────────────────

(defun dedup-path (list-id)
  "Return pathname for the dedup cache for LIST-ID."
  (merge-pathnames (format nil "state/dedup/~A.sexp" list-id)
                   (mlisp-home)))

(defun load-dedup (list-id)
  "Load dedup cache for LIST-ID. Returns list of (:id :timestamp) plists."
  (let ((path (dedup-path list-id)))
    (if (probe-file path)
        (with-open-file (s path :direction :input)
          (or (ignore-errors (read s)) '()))
        '())))

(defun save-dedup (list-id entries)
  "Persist dedup ENTRIES for LIST-ID atomically."
  (let* ((path (dedup-path list-id))
         (tmp  (format nil "~A.tmp" path)))
    (ensure-directories-exist path)
    (with-open-file (s tmp :direction :output
                           :if-exists :supersede
                           :if-does-not-exist :create)
      (let ((*print-pretty* nil) (*print-case* :downcase)
            (*print-readably* nil) (*print-escape* t))
        (write entries :stream s)
        (terpri s)))
    (rename-file tmp path)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Message-Id extraction and fingerprinting
;;; ─────────────────────────────────────────────────────────────────────────────

(defun message-id (headers body-lines)
  "Return a dedup key for the message.
   Prefers Message-Id header; falls back to a content fingerprint."
  (let ((mid (header-value headers "Message-Id")))
    (if (and mid (> (length mid) 0))
        (string-trim '(#\Space #\Tab #\< #\>) mid)
        ;; Fallback fingerprint: From + Subject + Date + first 64 chars of body
        (let ((from    (or (header-value headers "From") ""))
              (subject (or (header-value headers "Subject") ""))
              (date    (or (header-value headers "Date") ""))
              (body64  (if body-lines
                           (subseq (or (first body-lines) "")
                                   0 (min 64 (length (or (first body-lines) ""))))
                           "")))
          ;; Simple hash: concatenate and compute djb2-style integer
          (let ((str (concatenate 'string from "|" subject "|" date "|" body64)))
            (format nil "fingerprint-~A"
                    (reduce (lambda (h c)
                              (logand #xFFFFFFFF
                                      (+ (ash h 5) h (char-code c))))
                            str :initial-value 5381)))))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Dedup check and record
;;; ─────────────────────────────────────────────────────────────────────────────

(defun list-dedup-window (list-id)
  "Return dedup window in hours for LIST-ID."
  (or (getf (find-list list-id) :dedup-window-hours) 24))

(defun list-dedup-size (list-id)
  "Return max dedup cache entries for LIST-ID."
  (or (getf (find-list list-id) :dedup-size) 500))

(defun duplicate-p (list-id msg-id)
  "Return T if MSG-ID was seen for LIST-ID within the dedup window."
  (let* ((window-secs (* (list-dedup-window list-id) 3600))
         (now         (get-universal-time))
         (entries     (load-dedup list-id)))
    (some (lambda (e)
            (and (string= (getf e :id) msg-id)
                 (< (- now (getf e :seen-at 0)) window-secs)))
          entries)))

(defun record-dedup (list-id msg-id)
  "Add MSG-ID to the dedup cache for LIST-ID; evict old entries."
  (let* ((window-secs (* (list-dedup-window list-id) 3600))
         (max-size    (list-dedup-size list-id))
         (now         (get-universal-time))
         (entries     (load-dedup list-id))
         ;; Remove expired entries
         (fresh       (remove-if (lambda (e)
                                   (>= (- now (getf e :seen-at 0)) window-secs))
                                 entries))
         ;; Trim to max-size - 1
         (trimmed     (if (>= (length fresh) max-size)
                          (subseq fresh 0 (1- max-size))
                          fresh))
         ;; Prepend new entry
         (updated     (cons (list :id msg-id :seen-at now) trimmed)))
    (save-dedup list-id updated)))

(defun dedup-entries (list-id)
  "Return all current dedup cache entries for LIST-ID."
  (load-dedup list-id))

(defun clear-dedup-cache (list-id)
  "Flush the entire dedup cache for LIST-ID."
  (save-dedup list-id '()))
