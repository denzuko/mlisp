;;;; src/metrics.lisp — File-based Prometheus metrics exporter
;;;;
;;;; Writes OpenMetrics text format to $MLISP_HOME/metrics/mlisp.prom
;;;; Compatible with node_exporter --collector.textfile.directory
;;;;
;;;; Privacy guarantee: no pixels, no URL tracking, no cookies, no GTM.
;;;; Delivery tracking uses RFC 8098 MDN / RFC 3461 DSN headers only.

(in-package #:mlisp)

;;; Forward declarations
(declaim (special mlisp:*state*))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; In-memory counters (reset to state on each invocation)
;;; ─────────────────────────────────────────────────────────────────────────────

(defparameter *metric-events* '()
  "Accumulated events for this invocation: ((list action) ...)")

(defun record-metric (list-id action)
  "Record a metric event for LIST-ID and ACTION keyword."
  (push (list list-id action) *metric-events*))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; OpenMetrics writer
;;; ─────────────────────────────────────────────────────────────────────────────

(defun write-metrics-file ()
  "Atomically write OpenMetrics text to (metrics-path).
   Reads current state for gauge values; uses *metric-events* for counters."
  (ignore-errors
    (let ((path (metrics-path))
          (tmp  (format nil "~A.tmp.~A"
                        (metrics-path)
                        (get-universal-time))))
      (ensure-directories-exist path)
      (with-open-file (s tmp :direction :output
                             :if-exists :supersede
                             :if-does-not-exist :create)
        ;; Header
        (format s "# mlisp Prometheus metrics~%")
        (format s "# Generated: ~A~%" (iso8601-now))
        (format s "#~%")

        ;; mlisp_subscribers_total (gauge)
        (format s "# HELP mlisp_subscribers_total Current subscriber count per list~%")
        (format s "# TYPE mlisp_subscribers_total gauge~%")
        (when *state*
          (dolist (lst (getf *state* :lists))
            (format s "mlisp_subscribers_total{list=~S} ~A~%"
                    (getf lst :id)
                    (length (getf lst :subscribers)))))
        (terpri s)

        ;; mlisp_messages_total (counter — from this invocation's events)
        (format s "# HELP mlisp_messages_total Messages processed per list and action~%")
        (format s "# TYPE mlisp_messages_total counter~%")
        (let ((counts (make-hash-table :test #'equal)))
          (dolist (ev *metric-events*)
            (let ((key (format nil "~A/~A" (first ev) (second ev))))
              (setf (gethash key counts)
                    (1+ (or (gethash key counts) 0)))))
          (maphash (lambda (key count)
                     (destructuring-bind (list-id action)
                         (let ((slash (position #\/ key)))
                           (list (subseq key 0 slash)
                                 (subseq key (1+ slash))))
                       (format s "mlisp_messages_total{list=~S,action=~S} ~A~%"
                               list-id action count)))
                   counts))
        (terpri s)

        ;; mlisp_bounces_total (gauge from state)
        (format s "# HELP mlisp_bounces_total Total bounce count per list~%")
        (format s "# TYPE mlisp_bounces_total gauge~%")
        (when *state*
          (dolist (lst (getf *state* :lists))
            (let ((total (reduce #'+ (getf lst :subscribers)
                                 :key (lambda (r) (or (getf r :bounce-count) 0))
                                 :initial-value 0)))
              (format s "mlisp_bounces_total{list=~S} ~A~%"
                      (getf lst :id) total))))
        (terpri s)

        ;; mlisp_loop_drops_total (counter)
        (format s "# HELP mlisp_loop_drops_total Loop-detected messages dropped~%")
        (format s "# TYPE mlisp_loop_drops_total counter~%")
        (let ((drops (count-if (lambda (e) (eq (second e) :loop-drop))
                               *metric-events*)))
          (when (> drops 0)
            (dolist (lst (when *state* (getf *state* :lists)))
              (let ((list-drops
                     (count-if (lambda (e)
                                 (and (string= (first e) (getf lst :id))
                                      (eq (second e) :loop-drop)))
                               *metric-events*)))
                (when (> list-drops 0)
                  (format s "mlisp_loop_drops_total{list=~S} ~A~%"
                          (getf lst :id) list-drops))))))
        (terpri s)

        ;; mlisp_commands_total (counter)
        (format s "# HELP mlisp_commands_total Administrative commands processed~%")
        (format s "# TYPE mlisp_commands_total counter~%")
        (dolist (action '(:subscribe :unsubscribe :help :auto-subscribed))
          (let ((cmd-name (string-downcase (symbol-name action))))
            (dolist (lst (when *state* (getf *state* :lists)))
              (let ((n (count-if (lambda (e)
                                   (and (string= (first e) (getf lst :id))
                                        (eq (second e) action)))
                                 *metric-events*)))
                (when (> n 0)
                  (format s "mlisp_commands_total{list=~S,command=~S} ~A~%"
                          (getf lst :id) cmd-name n))))))
        (terpri s)

        ;; EOF marker (OpenMetrics spec)
        (format s "# EOF~%"))

      ;; Atomic rename
      (rename-file tmp path))))
