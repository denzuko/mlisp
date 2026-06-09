;;;; src/diagnose.lisp — List diagnosis report and multigram bounce threshold
;;;;
;;;; Diagnosis: health report sent via email (diagnose command) or stdout
;;;; (mlisp-admin diagnose). Also feeds Prometheus metrics file.
;;;;
;;;; Multigram bounce: time-windowed counting with soft/hard distinction.

(in-package #:mlisp)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Multigram bounce threshold
;;; ─────────────────────────────────────────────────────────────────────────────

(defun list-bounce-window-days (list-id)
  "Return bounce window in days. 0 = no windowing (original behaviour)."
  (or (getf (find-list list-id) :bounce-window-days) 30))

(defun bounce-hard-p (dsn-action)
  "Return T if DSN action string indicates a hard (permanent) bounce."
  (let ((a (string-downcase (or dsn-action ""))))
    (or (search "failed" a) (search "failure" a)
        (search "5." a))))   ; 5xx status code prefix

(defun maybe-reset-bounce (list-id address)
  "Reset bounce count if last delivery > last bounce (delivery success window).
   Called after each successful distribute-message delivery to a subscriber."
  (let* ((lst (find-list list-id))
         (sub (find-subscriber list-id address)))
    (when (and lst sub)
      (let ((last-del  (getf sub :last-delivery-at 0))
            (last-bnc  (getf sub :last-bounce-at 0)))
        (when (> last-del last-bnc)
          (if (member :bounce-count sub)
              (setf (getf sub :bounce-count) 0)
              (nconc sub (list :bounce-count 0))))))))

(defun record-delivery-success (list-id address)
  "Record that ADDRESS received a delivery on LIST-ID (for bounce reset logic)."
  (let ((sub (find-subscriber list-id address)))
    (when sub
      (let ((now (get-universal-time)))
        (if (member :last-delivery-at sub)
            (setf (getf sub :last-delivery-at) now)
            (nconc sub (list :last-delivery-at now))))
      (maybe-reset-bounce list-id address))))

(defun windowed-increment-bounce (list-id address dsn-action)
  "Increment bounce count with time-windowing and soft/hard distinction.
   Returns T if subscriber should be removed (threshold exceeded)."
  (let* ((sub     (find-subscriber list-id address))
         (lst     (find-list list-id))
         (window  (* (list-bounce-window-days list-id) 86400))
         (now     (get-universal-time))
         (hard-p  (bounce-hard-p dsn-action))
         (max-b   (or (getf lst :max-bounces) 5)))
    (unless sub (return-from windowed-increment-bounce nil))
    (let* ((last-bnc (getf sub :last-bounce-at 0))
           (cur-cnt  (getf sub :bounce-count 0))
           (new-cnt  (if (and (> window 0) (> (- now last-bnc) window))
                         1        ; outside window — reset to 1
                         (1+ cur-cnt))))
      ;; Update subscriber record
      (when hard-p
        (if (member :bounce-count sub)
            (setf (getf sub :bounce-count) new-cnt)
            (nconc sub (list :bounce-count new-cnt)))
        (if (member :last-bounce-at sub)
            (setf (getf sub :last-bounce-at) now)
            (nconc sub (list :last-bounce-at now))))
      ;; Return T if should remove
      (and hard-p (>= new-cnt max-b)))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Diagnosis data collection
;;; ─────────────────────────────────────────────────────────────────────────────

(defun list-last-post-time (list-id)
  "Return unix timestamp of most recent :post-distributed event for LIST-ID, or 0."
  (let* ((audit-path (merge-pathnames "state/audit.sexp" (mlisp-home)))
         (audit (when (probe-file audit-path)
                  (with-open-file (s audit-path)
                    (ignore-errors (read s)))))
         (events (remove-if-not
                  (lambda (e) (and (eq (getf e :event) :post-distributed)
                                   (equal (getf e :list) list-id)))
                  (if (listp audit) audit '()))))
    (if events
        (reduce #'max events :key (lambda (e) (or (getf e :at) 0)))
        0)))

(defun missing-templates (list-id)
  "Return list of expected template names that are absent."
  (let ((tmpl-dir (merge-pathnames "templates/" (mlisp-home))))
    (remove-if (lambda (name)
                 (probe-file (merge-pathnames
                              (format nil "~A.~A.sexp" list-id name)
                              tmpl-dir)))
               '("welcome" "goodbye" "help" "footer"))))

(defun subscribers-near-bounce (list-id)
  "Return count of subscribers within 1 bounce of removal threshold."
  (let* ((lst (find-list list-id))
         (max-b (or (getf lst :max-bounces) 5))
         (subs  (list-subscribers list-id)))
    (count-if (lambda (s)
                (>= (getf s :bounce-count 0) (1- max-b)))
              subs)))

(defstruct diag
  list-id subgroup drop request
  sub-total sub-nomail sub-pending sub-hashed
  bounce-near-threshold
  held-depth digest-depth dedup-size
  last-post-ts
  locked moderated delivery-mode confirm-subscribe
  max-size max-bounces bounce-window-days non-member-action
  dmarc-rewrite reply-to verp
  missing-templates)

(defun collect-diagnosis (list-id)
  "Collect all diagnostic data for LIST-ID. Returns a DIAG struct."
  (let* ((lst  (find-list list-id))
         (subs (list-subscribers list-id)))
    (make-diag
     :list-id           list-id
     :subgroup          (list-subgroup list-id)
     :drop              (list-drop-address list-id)
     :request           (list-request-address list-id)
     :sub-total         (length subs)
     :sub-nomail        (count-if (lambda (s) (getf s :nomail)) subs)
     :sub-pending       (length (pending-entries list-id))
     :sub-hashed        (count-if (lambda (s) (getf s :address-hash)) subs)
     :bounce-near-threshold (subscribers-near-bounce list-id)
     :held-depth        (length (held-queue list-id))
     :digest-depth      (length (load-queue (digest-buffer-path list-id)))
     :dedup-size        (length (dedup-entries list-id))
     :last-post-ts      (list-last-post-time list-id)
     :locked            (getf lst :locked)
     :moderated         (getf lst :moderated)
     :delivery-mode     (or (getf lst :delivery-mode) :individual)
     :confirm-subscribe (confirm-subscribe-p list-id)
     :max-size          (or (getf lst :max-message-size-kb) 0)
     :max-bounces       (or (getf lst :max-bounces) 5)
     :bounce-window-days (list-bounce-window-days list-id)
     :non-member-action (or (getf lst :non-member-action) :reject)
     :dmarc-rewrite     (or (getf lst :dmarc-rewrite) :auto)
     :reply-to          (or (getf lst :reply-to-munging) :none)
     :verp              (getf lst :verp)
     :missing-templates (missing-templates list-id))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Diagnosis report formatting
;;; ─────────────────────────────────────────────────────────────────────────────

(defun format-diagnosis (d)
  "Return diagnosis report as a plain-text string."
  (with-output-to-string (s)
    (format s "mlisp list diagnosis: ~A~%" (diag-list-id d))
    (format s "~A~%~%" (make-string 60 :initial-element #\-))
    (format s "Addresses~%")
    (format s "  drop:     ~A~%" (diag-drop d))
    (format s "  request:  ~A~%~%" (diag-request d))
    (format s "Subscribers~%")
    (format s "  total:      ~A~%" (diag-sub-total d))
    (format s "  nomail:     ~A~%" (diag-sub-nomail d))
    (format s "  pending:    ~A  (awaiting confirmation)~%" (diag-sub-pending d))
    (format s "  hashed:     ~A  (hash-at-rest)~%~%" (diag-sub-hashed d))
    (format s "Bounce status~%")
    (format s "  max-bounces:      ~A~%" (diag-max-bounces d))
    (format s "  window-days:      ~A~@[ (0=no window)~]~%"
            (diag-bounce-window-days d) (zerop (diag-bounce-window-days d)))
    (format s "  near-threshold:   ~A subscriber~:P~%~%" (diag-bounce-near-threshold d))
    (format s "Queues~%")
    (format s "  held queue:       ~A message~:P~%" (diag-held-depth d))
    (format s "  digest buffer:    ~A message~:P~%" (diag-digest-depth d))
    (format s "  dedup cache:      ~A entry/ies~%~%" (diag-dedup-size d))
    (format s "Configuration~%")
    (format s "  locked:           ~A~%" (if (diag-locked d) "YES" "no"))
    (format s "  moderated:        ~A~%" (if (diag-moderated d) "yes" "no"))
    (format s "  delivery-mode:    ~A~%" (diag-delivery-mode d))
    (format s "  confirm-subscribe:~A~%" (if (diag-confirm-subscribe d) "yes (double opt-in)" "no"))
    (format s "  max-message-size: ~A KB (~A)~%"
            (diag-max-size d) (if (zerop (diag-max-size d)) "unlimited" "enforced"))
    (format s "  non-member:       ~A~%" (diag-non-member-action d))
    (format s "  dmarc-rewrite:    ~A~%" (diag-dmarc-rewrite d))
    (format s "  reply-to-munging: ~A~%" (diag-reply-to d))
    (format s "  verp:             ~A~%~%" (if (diag-verp d) "enabled" "disabled"))
    (if (diag-missing-templates d)
        (progn
          (format s "WARNINGS~%")
          (dolist (t- (diag-missing-templates d))
            (format s "  MISSING template: ~A.~A.sexp~%"
                    (diag-list-id d) t-))
          (terpri s))
        (format s "Templates: all present~%~%"))
    (if (> (diag-last-post-ts d) 0)
        (format s "Last post: ~A (unix)~%"
                (diag-last-post-ts d))
        (format s "Last post: never (no audit record)~%"))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Diagnosis command handler (email delivery)
;;; ─────────────────────────────────────────────────────────────────────────────

(defun handle-diagnose (list-id from-addr)
  "Send diagnosis report to FROM-ADDR for LIST-ID."
  (let* ((d    (collect-diagnosis list-id))
         (body (format-diagnosis d))
         (drop (list-drop-address list-id)))
    (sendmail (list from-addr) body
              :extra-headers
              (list (cons "Subject"
                          (format nil "[~A] List diagnosis report" list-id))
                    (cons "From" drop)
                    (cons "To"   from-addr)))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Extended Prometheus metrics (diagnosis)
;;; ─────────────────────────────────────────────────────────────────────────────

(defun write-extended-metrics ()
  "Append extended diagnosis metrics to the Prometheus textfile.
   Called from write-metrics-file after the base metrics."
  (ignore-errors
    (let* ((metrics-dir (merge-pathnames "metrics/" (mlisp-home)))
           (path        (merge-pathnames "mlisp.prom" metrics-dir))
           (tmp         (format nil "~A.tmp" path)))
      (ensure-directories-exist path)
      ;; Read existing file content (base metrics already written)
      ;; Append extended metrics
      (with-open-file (s tmp :direction :output
                             :if-exists :supersede
                             :if-does-not-exist :create)
        ;; Copy base metrics
        (when (probe-file path)
          (with-open-file (base path)
            (loop for line = (read-line base nil nil) while line
                  do (write-line line s))))
        ;; Extended metrics header
        (format s "# Extended diagnosis metrics~%")
        (format s "# TYPE mlisp_subscribers_nomail_total gauge~%")
        (format s "# TYPE mlisp_subscribers_pending_total gauge~%")
        (format s "# TYPE mlisp_subscribers_near_bounce gauge~%")
        (format s "# TYPE mlisp_list_locked gauge~%")
        (format s "# TYPE mlisp_list_moderated gauge~%")
        (format s "# TYPE mlisp_held_queue_depth gauge~%")
        (format s "# TYPE mlisp_digest_buffer_depth gauge~%")
        (format s "# TYPE mlisp_dedup_cache_size gauge~%")
        (format s "# TYPE mlisp_last_post_timestamp gauge~%")
        (format s "# TYPE mlisp_pending_confirmations_total gauge~%")
        ;; Per-list values
        (let ((lists (getf *state* :lists)))
          (dolist (lst lists)
            (let* ((id (getf lst :id))
                   (d  (ignore-errors (collect-diagnosis id))))
              (when d
                (flet ((emit (metric value)
                         (format s "~A{list_id=\"~A\"} ~A~%" metric id value)))
                  (emit "mlisp_subscribers_nomail_total"    (diag-sub-nomail d))
                  (emit "mlisp_subscribers_pending_total"   (diag-sub-pending d))
                  (emit "mlisp_subscribers_near_bounce"     (diag-bounce-near-threshold d))
                  (emit "mlisp_list_locked"    (if (diag-locked d) 1 0))
                  (emit "mlisp_list_moderated" (if (diag-moderated d) 1 0))
                  (emit "mlisp_held_queue_depth"      (diag-held-depth d))
                  (emit "mlisp_digest_buffer_depth"   (diag-digest-depth d))
                  (emit "mlisp_dedup_cache_size"      (diag-dedup-size d))
                  (emit "mlisp_last_post_timestamp"   (diag-last-post-ts d))
                  (emit "mlisp_pending_confirmations_total" (diag-sub-pending d))))))))
      (rename-file tmp path))))
