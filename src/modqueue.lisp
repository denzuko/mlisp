;;;; src/modqueue.lisp — Moderation held queue and digest buffer
;;;;
;;;; Moderation: posts to moderated lists are written to state/held/<list>.sexp
;;;; and distributed only on explicit mlisp-admin approve.
;;;;
;;;; Digest: posts to digest-mode lists are buffered in state/digest/<list>.sexp
;;;; and flushed on demand (mlisp-admin flush-digest) or by cron.

(in-package #:mlisp)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Path helpers
;;; ─────────────────────────────────────────────────────────────────────────────

(defun held-queue-path (list-id)
  (merge-pathnames (format nil "state/held/~A.sexp" list-id) (mlisp-home)))

(defun digest-buffer-path (list-id)
  (merge-pathnames (format nil "state/digest/~A.sexp" list-id) (mlisp-home)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Generic queue I/O
;;; ─────────────────────────────────────────────────────────────────────────────

(defun load-queue (path)
  (if (probe-file path)
      (with-open-file (s path) (or (ignore-errors (read s)) '()))
      '()))

(defun save-queue (path entries)
  (let ((tmp (format nil "~A.tmp" path)))
    (ensure-directories-exist path)
    (with-open-file (s tmp :direction :output :if-exists :supersede
                           :if-does-not-exist :create)
      (let ((*print-pretty* t) (*print-case* :downcase)
            (*print-readably* nil) (*print-escape* t))
        (write entries :stream s) (terpri s)))
    (rename-file tmp path)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Moderation held queue
;;; ─────────────────────────────────────────────────────────────────────────────

(defun list-moderated-p (list-id)
  "Return T if the list has :moderated t."
  (getf (find-list list-id) :moderated))

(defun hold-message (list-id headers body-lines)
  "Add message to the held queue for LIST-ID. Returns sequence number."
  (let* ((path    (held-queue-path list-id))
         (queue   (load-queue path))
         (seq     (1+ (length queue)))
         (entry   (list :seq seq
                        :received (iso8601-now)
                        :from (header-value headers "From")
                        :subject (header-value headers "Subject")
                        :headers headers
                        :body body-lines)))
    (save-queue path (append queue (list entry)))
    seq))

(defun held-queue (list-id)
  "Return all entries in the held queue for LIST-ID."
  (load-queue (held-queue-path list-id)))

(defun release-held (list-id seq)
  "Remove and return the held entry with sequence number SEQ."
  (let* ((path  (held-queue-path list-id))
         (queue (load-queue path))
         (entry (find seq queue :key (lambda (e) (getf e :seq)))))
    (when entry
      (save-queue path (remove seq queue :key (lambda (e) (getf e :seq))))
      entry)))

(defun purge-held (list-id seq)
  "Remove held entry SEQ without returning/distributing it."
  (let* ((path  (held-queue-path list-id))
         (queue (load-queue path)))
    (save-queue path (remove seq queue :key (lambda (e) (getf e :seq))))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Digest buffer
;;; ─────────────────────────────────────────────────────────────────────────────

(defun list-digest-mode-p (list-id)
  "Return T if list :delivery-mode is :digest."
  (let ((mode (getf (find-list list-id) :delivery-mode)))
    (or (eq mode :digest)
        (and (stringp mode) (string-equal mode "digest")))))

(defun buffer-for-digest (list-id headers body-lines)
  "Append message to the digest buffer for LIST-ID."
  (let* ((path  (digest-buffer-path list-id))
         (buf   (load-queue path))
         (entry (list :received (iso8601-now)
                      :from (header-value headers "From")
                      :subject (header-value headers "Subject")
                      :headers headers
                      :body body-lines)))
    (save-queue path (append buf (list entry)))))

(defun digest-next-number (list-id)
  "Return (volume . issue) for the next digest."
  (let* ((lst   (find-list list-id))
         (vol   (or (getf lst :digest-volume) 1))
         (issue (or (getf lst :digest-issue) 0)))
    (cons vol (1+ issue))))

(defun flush-digest (list-id)
  "Assemble and distribute digest for LIST-ID. Clears buffer on success.
   Returns number of articles flushed (0 if nothing to flush)."
  (let* ((path    (digest-buffer-path list-id))
         (buf     (load-queue path)))
    (when (null buf)
      (return-from flush-digest 0))
    (let* ((lst      (find-list list-id))
           (voliss   (digest-next-number list-id))
           (vol      (car voliss))
           (issue    (cdr voliss))
           (drop     (list-drop-address list-id))
           (subj     (format nil "[~A] Digest Vol ~A Issue ~A"
                             list-id vol issue))
           ;; Build digest body
           (body
            (with-output-to-string (s)
              (format s "~A Digest Vol ~A Issue ~A~%~
Topics in this digest:~%~%"
                      (string-upcase list-id) vol issue)
              (let ((n 1))
                (dolist (e buf)
                  (format s "  ~A. ~A~%" n (or (getf e :subject) "(no subject)"))
                  (incf n)))
              (format s "~%~%")
              ;; Individual articles
              (let ((n 1))
                (dolist (e buf)
                  (format s "~%----------------------------------------------------------------------~%")
                  (format s "Message ~A: ~A~%From: ~A~%~%"
                          n
                          (or (getf e :subject) "(no subject)")
                          (or (getf e :from) ""))
                  (dolist (line (getf e :body))
                    (write-line line s))
                  (incf n)))
              (format s "~%----------------------------------------------------------------------~%")
              (write-string (compliance-footer-text list-id) s))))
      ;; Deliver to subscribers
      (let ((addrs (subscriber-addresses list-id))
            (extra-hdrs (append
                         (rfc2369-headers list-id)
                         (list (cons "Subject"  subj)
                               (cons "Sender"   drop)
                               (cons "Reply-To" drop)
                               (cons "To"       drop)
                               (cons (list-loop-header list-id) "1")))))
        (dolist (addr addrs)
          (sendmail (list addr) body :extra-headers extra-hdrs)))
      ;; Update volume/issue in state, clear buffer
      (setf (getf lst :digest-volume) vol)
      (setf (getf lst :digest-issue) issue)
      (save-state)
      (save-queue path '())
      (audit-append (list :event :digest-flushed :list list-id
                          :articles (length buf) :volume vol :issue issue))
      (record-metric list-id :digest-flush)
      (length buf))))
