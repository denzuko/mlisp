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
           ;; 4. Subscriber authorization
           (if (subscriber-p list-id from-addr)
               (progn
                 (distribute-message list-id from-addr headers body-lines)
                 (audit-append (list :event :post-distributed
                                     :list list-id :from from-addr))
                 0)
               (progn
                 (handle-reject list-id from-addr)
                 (audit-append (list :event :post-rejected
                                     :list list-id :from from-addr))
                 1))))))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Entry point
;;; ─────────────────────────────────────────────────────────────────────────────

(defun main ()
  "CLI entry point. argv[1] = list-id."
  (let ((args (cdr sb-ext:*posix-argv*)))
    (when (or (null args)
              (member "--help" args :test #'string=)
              (member "-h" args :test #'string=))
      (format t "Usage: mlisp <list-id>~%~
Reads raw email from stdin and routes to the named mailing list.~%")
      (sb-ext:exit :code 0))

    (let ((list-id (string-downcase (first args))))
      (handler-case
          (progn
            (load-state)
            (let ((code (process-message list-id)))
              (sb-ext:exit :code code)))
        (error (e)
          (format *error-output* "mlisp: fatal: ~A~%" e)
          (sb-ext:exit :code 2))))))
