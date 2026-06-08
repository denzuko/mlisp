;;;; src/main.lisp — Core processing pipeline and CLI entry point

(in-package #:mlisp)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Core processing pipeline
;;; ─────────────────────────────────────────────────────────────────────────────

(defun process-message (list-id)
  "Full pipeline: read stdin, parse, dispatch. Returns exit code (0 or 1)."
  (multiple-value-bind (headers body-lines _raw)
      (read-message-from-stdin)
    (declare (ignore _raw))
    (let* ((from-addr (or (extract-address (header-value headers "From"))
                          (extract-address (header-value headers "Return-Path"))
                          "unknown@unknown"))
           (loop-hdr  (list-loop-header list-id)))

      ;; 1. Loop detection
      (when (header-value headers loop-hdr)
        (format *error-output* "mlisp: loop detected on ~A, dropping.~%" list-id)
        (record-metric list-id :loop-drop)
        (return-from process-message 0))

      ;; 1b. Daemon / auto-responder discrimination
      (when (daemon-message-p headers)
        (let ((reason (daemon-drop-reason headers)))
          (format *error-output* "mlisp: daemon message (~A) dropped on ~A~%"
                  reason list-id)
          (audit-append (list :event :daemon-drop :list list-id
                              :reason reason :from from-addr))
          (record-metric list-id :daemon-drop))
        (return-from process-message 0))

      ;; 2. Find list
      (unless (find-list list-id)
        (format *error-output* "mlisp: unknown list ~A~%" list-id)
        (return-from process-message 1))

      ;; 3. Command dispatch
      (let ((cmd (detect-command headers body-lines)))
        (case cmd
          (:subscribe
           (handle-subscribe list-id from-addr)
           0)
          (:unsubscribe
           (handle-unsubscribe list-id from-addr)
           0)
          (:help
           (handle-help list-id from-addr)
           0)
          (t
           ;; 4. Request mode: reject posts
           (when (eq *process-mode* :request)
             (format *error-output*
                     "mlisp: --mode request: posts not accepted on ~A; use list address~%"
                     list-id)
             (record-metric list-id :request-reject)
             (return-from process-message 1))
           ;; 5. Exploder bypass: relay lists don't check per-list subscription
           (when (list-exploder-p list-id)
             (distribute-exploder list-id from-addr headers body-lines)
             (audit-append (list :event :post-distributed :list list-id :from from-addr))
             (record-metric list-id :distributed)
             (return-from process-message 0))
           ;; 6. Auto-subscribe on first post (if enabled)
           (when (and (not (subscriber-p list-id from-addr))
                      (list-auto-subscribe-p list-id))
             (handle-subscribe list-id from-addr)
             (audit-append (list :event :auto-subscribed
                                 :list list-id :address from-addr)))
           ;; 7. Subscriber authorization
           (if (subscriber-p list-id from-addr)
               (let* ((msg-id (message-id headers body-lines)))
                 ;; 7. Dedup check
                 (when (duplicate-p list-id msg-id)
                   (audit-append (list :event :duplicate :list list-id
                                       :message-id msg-id))
                   (record-metric list-id :duplicate)
                   (return-from process-message 0))
                 (record-dedup list-id msg-id)
                 ;; 8. Exploder dispatch
                 (cond
                   ((list-exploder-p list-id)
                    (distribute-exploder list-id from-addr headers body-lines))
                   ;; 9. Moderation hold queue
                   ((list-moderated-p list-id)
                    (let ((seq (hold-message list-id headers body-lines)))
                      (audit-append (list :event :held :list list-id
                                          :seq seq :from from-addr))
                      (record-metric list-id :held)))
                   ;; 10. Digest buffer
                   ((list-digest-mode-p list-id)
                    (buffer-for-digest list-id headers body-lines)
                    (audit-append (list :event :buffered-for-digest
                                        :list list-id :from from-addr)))
                   ;; 11. Normal distribution
                   (t
                    (maybe-archive-to-maildir list-id headers body-lines)
                    (distribute-message list-id from-addr headers body-lines)
                    (audit-append (list :event :post-distributed
                                        :list list-id :from from-addr))
                    (record-metric list-id :distributed)))
                 0)
               (progn
                 (handle-reject list-id from-addr)
                 (audit-append (list :event :post-rejected
                                     :list list-id :from from-addr))
                 (record-metric list-id :rejected)
                 1))))))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Argument parsing (shared by mlisp and mlisp-admin)
;;; ─────────────────────────────────────────────────────────────────────────────

(defun parse-common-flags (args)
  "Extract --home and --mode from ARGS.
   Returns (values home-dir mode remaining-args)."
  (let ((home nil)
        (mode :normal)
        (rest '()))
    (do ((tail args (cdr tail)))
        ((null tail))
      (let ((a (car tail)))
        (cond
          ((string= a "--home")
           (if (cdr tail)
               (progn (setf home (cadr tail))
                      (setf tail (cdr tail)))
               (error "--home requires a directory argument")))
          ((string= a "--mode")
           (if (cdr tail)
               (progn
                 (setf mode (intern (string-upcase (cadr tail)) :keyword))
                 (setf tail (cdr tail)))
               (error "--mode requires an argument (normal, request, bounce)")))
          (t (push a rest)))))
    (values home mode (nreverse rest))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Entry point
;;; ─────────────────────────────────────────────────────────────────────────────

(defun main ()
  "CLI entry point.
   Usage: mlisp [--home <dir>] <list-id>
   Reads raw email from stdin and routes to the named mailing list."
  (let ((args (cdr sb-ext:*posix-argv*)))
    (when (or (null args)
              (member "--help" args :test #'string=)
              (member "-h" args :test #'string=))
      (format t
"Usage: mlisp [--home <dir>] <list-id>

Options:
  --home <dir>   Config directory (overrides MLISP_HOME and XDG paths)
  -h, --help     Show this help

Reads raw email from stdin and routes to the named mailing list.
Config resolution order:
  --home > $MLISP_HOME > $XDG_CONFIG_HOME/mlisp/ > ~~/.config/mlisp/ > binary dir
")
      (sb-ext:exit :code 0))

    (multiple-value-bind (home-dir mode remaining)
        (parse-common-flags args)
      (when home-dir
        (setf *mlisp-home-override* home-dir))
      (setf *process-mode* mode)
      (when (null remaining)
        (format *error-output* "mlisp: error: list-id required~%")
        (sb-ext:exit :code 1))
      (let ((list-id (string-downcase (first remaining))))
        (handler-case
            (progn
              (load-state)
              (let ((code (case mode
                            (:bounce  (process-bounce list-id))
                            (t        (process-message list-id)))))
                (write-metrics-file)
                (sb-ext:exit :code code)))
          (error (e)
            (format *error-output* "mlisp: fatal: ~A~%" e)
            (sb-ext:exit :code 2)))))))
