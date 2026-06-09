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

      ;; 0. Max message size check
      (let ((max-kb (or (getf (find-list list-id) :max-message-size-kb) 0)))
        (when (> max-kb 0)
          (let* ((body-size (reduce #'+ body-lines :key #'length :initial-value 0))
                 (hdr-size  (reduce #'+ headers
                                    :key (lambda (h)
                                           (+ (length (car h)) (length (cdr h)) 4))
                                    :initial-value 0))
                 (total-kb  (ceiling (+ body-size hdr-size) 1024)))
            (when (> total-kb max-kb)
              (format *error-output*
                      "mlisp: message too large (~AKB, max ~AKB) on ~A~%"
                      total-kb max-kb list-id)
              (audit-append (list :event :size-rejected :list list-id
                                  :size-kb total-kb :max-kb max-kb))
              (return-from process-message 1)))))

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

      ;; 3. Command dispatch — skip for :request subgroup (has its own full handler)
      (let ((cmd (unless (eq (list-subgroup list-id) :request)
                   (detect-command headers body-lines))))
        (case cmd
          (:subscribe
           ;; Double opt-in check for subscribe on any list
           (if (confirm-subscribe-p list-id)
               (let ((token (add-pending list-id from-addr :subscribe)))
                 (send-subscribe-challenge list-id from-addr token)
                 (audit-append (list :event :subscribe-pending
                                     :list list-id :address from-addr)))
               (handle-subscribe list-id from-addr))
           0)
          (:confirm
           ;; Confirm token for early-dispatch lists
           (let* ((token (extract-confirm-token headers body-lines))
                  (entry (when (and token (> (length token) 4))
                           (validate-token list-id token))))
             (if entry
                 (progn
                   (consume-token list-id token)
                   (if (list-hash-contacts-p list-id)
                       (add-subscriber-hashed list-id from-addr)
                       (add-subscriber list-id from-addr))
                   (let ((sub (find-subscriber list-id from-addr)))
                     (when sub
                       (if (member :consent-method sub)
                           (setf (getf sub :consent-method) "double-opt-in")
                           (nconc sub (list :consent-method "double-opt-in")))))
                   (save-state)
                   (audit-append (list :event :subscribe-confirmed
                                       :list list-id :address from-addr))
                   (handle-welcome list-id from-addr))
                 (format *error-output*
                         "mlisp: invalid or expired confirmation token~%")))
           0)
          (:unsubscribe
           (handle-unsubscribe list-id from-addr)
           0)
          (:help
           (handle-help list-id from-addr)
           0)
          (:diagnose
           (handle-diagnose list-id from-addr)
           0)
          (:nomail
           (set-subscriber-nomail list-id from-addr t)
           (save-state)
           (audit-append (list :event :nomail-set :list list-id :address from-addr))
           0)
          (:resume
           (set-subscriber-nomail list-id from-addr nil)
           (save-state)
           (audit-append (list :event :mail-resumed :list list-id :address from-addr))
           0)
          (t
           ;; 3z. List locking — hold ALL posts when :locked t
           (when (getf (find-list list-id) :locked)
             (let ((seq (hold-message list-id headers body-lines)))
               (audit-append (list :event :locked-hold :list list-id
                                   :seq seq :from from-addr)))
             (return-from process-message 0))

           ;; 4a. :request subgroup — command-only regardless of --mode flag
           (when (eq (list-subgroup list-id) :request)
             (let ((cmd (detect-command headers body-lines)))
               (case cmd
                 (:subscribe
                  ;; Route to sibling: "subscribe discuss" → mlisp-discuss
                  (let* ((first-body (string-downcase (or (first body-lines) "")))
                         (subj       (string-downcase (or (header-value headers "Subject") "")))
                         (target-sg  (or
                                      (dolist (sg '("discuss" "announce" "devel" "distrib"))
                                        (when (or (search sg first-body)
                                                  (search sg subj))
                                          (return sg)))
                                      "discuss"))
                         (ns         (list-namespace list-id))
                         (target-id  (let ((candidate
                                            (when ns (format nil "~A-~A" ns target-sg))))
                                       (if (and candidate (find-list candidate))
                                           candidate
                                           list-id))))
                    ;; Double opt-in check
                    (if (confirm-subscribe-p target-id)
                        (let ((token (add-pending target-id from-addr :subscribe)))
                          (send-subscribe-challenge target-id from-addr token)
                          (audit-append (list :event :subscribe-pending
                                              :list target-id :address from-addr)))
                        (handle-subscribe target-id from-addr)))
                  (return-from process-message 0))
                 (:confirm
                  ;; Validate token and complete pending subscribe
                  (let* ((token     (extract-confirm-token headers body-lines))
                         (ns        (list-namespace list-id))
                         (siblings  (if ns (namespace-siblings list-id) (list (find-list list-id))))
                         (found     (when (and token (> (length token) 4))
                                      (dolist (sib siblings)
                                        (let ((e (validate-token (getf sib :id) token)))
                                          (when e (return (cons (getf sib :id) e)))))))
                         (target-id (when found (car found)))
                         (entry     (when found (cdr found))))
                    (if entry
                        (progn
                          (consume-token target-id token)
                          (if (list-hash-contacts-p target-id)
                              (add-subscriber-hashed target-id from-addr)
                              (add-subscriber target-id from-addr))
                          ;; Record double-opt-in consent
                          (let ((sub (find-subscriber target-id from-addr)))
                            (when sub
                              (if (member :consent-method sub)
                                  (setf (getf sub :consent-method) "double-opt-in")
                                  (nconc sub (list :consent-method "double-opt-in")))))
                          (save-state)
                          (audit-append (list :event :subscribe-confirmed
                                              :list target-id :address from-addr))
                          (handle-welcome target-id from-addr))
                        (format *error-output*
                                "mlisp: invalid or expired confirmation token~%")))
                  (return-from process-message 0))
                 (:unsubscribe
                  ;; Unsubscribe from all namespace subgroups
                  (let ((ns (list-namespace list-id)))
                    (when ns
                      (dolist (sibling (namespace-siblings list-id))
                        (remove-subscriber (getf sibling :id) from-addr)))
                    (save-state)
                    (audit-append (list :event :unsubscribe :list list-id
                                        :address from-addr)))
                  (return-from process-message 0))
                 (:help
                  (handle-help list-id from-addr)
                  (return-from process-message 0))
                 (:diagnose
                  ;; Send list health report to the requestor
                  (let* ((lst      (find-list list-id))
                         (ns       (list-namespace list-id))
                         (siblings (when ns (namespace-siblings list-id)))
                         (report
                          (with-output-to-string (s)
                            (format s "mlisp List Diagnosis Report~%")
                            (format s "Generated: ~A~%~%" (iso8601-now))
                            (dolist (target (or siblings (list lst)))
                              (let* ((tid   (getf target :id))
                                     (subs  (list-subscribers tid))
                                     (noml  (count-if (lambda (r) (getf r :nomail)) subs))
                                     (bounce-subs
                                      (remove-if-not
                                       (lambda (r) (> (or (getf r :bounce-count) 0) 0))
                                       subs)))
                                (format s "List: ~A~%" tid)
                                (format s "  subgroup:      ~A~%" (getf target :subgroup))
                                (format s "  drop:          ~A~%" (getf target :drop-address))
                                (format s "  request:       ~A~%" (getf target :request-address))
                                (format s "  subscribers:   ~A total, ~A NOMAIL~%"
                                        (length subs) noml)
                                (format s "  bouncing:      ~A subscriber~:P above 0 bounces~%"
                                        (length bounce-subs))
                                (format s "  locked:        ~A~%" (if (getf target :locked) "YES" "no"))
                                (format s "  moderated:     ~A~%" (if (getf target :moderated) "YES" "no"))
                                (format s "  delivery-mode: ~A~%"
                                        (or (getf target :delivery-mode) "individual"))
                                (format s "  max-size-kb:   ~A~%"
                                        (or (getf target :max-message-size-kb) "unlimited"))
                                (format s "  confirm-sub:   ~A~%"
                                        (if (confirm-subscribe-p tid) "yes" "no"))
                                (format s "  non-member:    ~A~%"
                                        (or (getf target :non-member-action) "reject"))
                                (terpri s))))))
                    (sendmail (list from-addr) report
                              :extra-headers
                              (list (cons "Subject"
                                          (format nil "Diagnosis: ~A" list-id))
                                    (cons "From" (list-drop-address list-id))
                                    (cons "To"   from-addr)))
                    (audit-append (list :event :diagnose :list list-id :from from-addr)))
                  (return-from process-message 0))
                 (:nomail
                  ;; Suspend delivery for this address across all namespace subgroups
                  (let ((ns (list-namespace list-id)))
                    (dolist (sibling (if ns
                                        (namespace-siblings list-id)
                                        (list (find-list list-id))))
                      (set-subscriber-nomail (getf sibling :id) from-addr t)))
                  (audit-append (list :event :nomail-set :list list-id :address from-addr))
                  (return-from process-message 0))
                 (:resume
                  ;; Resume delivery
                  (let ((ns (list-namespace list-id)))
                    (dolist (sibling (if ns
                                        (namespace-siblings list-id)
                                        (list (find-list list-id))))
                      (set-subscriber-nomail (getf sibling :id) from-addr nil)))
                  (audit-append (list :event :mail-resumed :list list-id :address from-addr))
                  (return-from process-message 0))
                 (:diagnose
                  (handle-diagnose list-id from-addr)
                  (return-from process-message 0))
                 (t
                  (format *error-output*
                          "mlisp: ~A is command-only; no posts accepted~%" list-id)
                  (record-metric list-id :request-reject)
                  (return-from process-message 1)))))
           ;; 4b. --mode request flag
           (when (eq *process-mode* :request)
             (format *error-output*
                     "mlisp: --mode request: posts not accepted on ~A; use list address~%"
                     list-id)
             (record-metric list-id :request-reject)
             (return-from process-message 1))
           ;; 4c. :announce subgroup — owner-post-only
           (when (list-announce-p list-id)
             (unless (owner-post-p list-id from-addr)
               (format *error-output*
                       "mlisp: ~A is announce-only; post rejected from ~A~%"
                       list-id from-addr)
               (record-metric list-id :announce-reject)
               (return-from process-message 1)))
           ;; 5. Exploder bypass: relay lists don't check per-list subscription
           (when (list-exploder-p list-id)
             (distribute-exploder list-id from-addr headers body-lines)
             (audit-append (list :event :post-distributed :list list-id :from from-addr))
             (record-metric list-id :distributed)
             (return-from process-message 0))
           ;; 6. Auto-subscribe on first post (if enabled)
           (let ((sub-check (if (list-hash-contacts-p list-id)
                                #'subscriber-p-hashed
                                #'subscriber-p)))
             (when (and (not (funcall sub-check list-id from-addr))
                        (list-auto-subscribe-p list-id))
               (handle-subscribe list-id from-addr)
               (audit-append (list :event :auto-subscribed
                                   :list list-id :address from-addr))))
           ;; 7. GPG signature check
           (when (list-require-signed-p list-id)
             (unless (gpg-signed-p headers body-lines)
               (audit-append (list :event :gpg-unsigned-rejected
                                   :list list-id :from from-addr))
               (record-metric list-id :gpg-rejected)
               (return-from process-message 1)))
           ;; 8. Subscriber authorization
           (if (or
                ;; Owner bypass for announce lists
                (and (list-announce-p list-id) (owner-post-p list-id from-addr))
                ;; Normal subscriber check
                (funcall (if (list-hash-contacts-p list-id)
                             #'subscriber-p-hashed
                             #'subscriber-p)
                         list-id from-addr))
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
               (let* ((raw    (getf (find-list list-id) :non-member-action))
                      (policy (cond
                                ((null raw) :reject)
                                ((keywordp raw) raw)
                                ((string-equal raw "hold")    :hold)
                                ((string-equal raw "discard") :discard)
                                (t :reject))))
                 (cond
                   ((eq policy :hold)
                    (let ((seq (hold-message list-id headers body-lines)))
                      (audit-append (list :event :non-member-held :list list-id
                                          :seq seq :from from-addr)))
                    0)
                   ((eq policy :discard)
                    (audit-append (list :event :non-member-discard :list list-id
                                        :from from-addr))
                    0)
                   (t  ; :reject (default)
                    (handle-reject list-id from-addr)
                    (audit-append (list :event :post-rejected
                                        :list list-id :from from-addr))
                    (record-metric list-id :rejected)
                    1))))))))))

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
                (write-extended-metrics)
                (sb-ext:exit :code code)))
          (error (e)
            (format *error-output* "mlisp: fatal: ~A~%" e)
            (sb-ext:exit :code 2)))))))
