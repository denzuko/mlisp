;;;; src/state.lisp — Runtime paths, state I/O, subscriber accessors
;;;; CAN-SPAM § 7704 / GDPR Art.7/17/30 data layer

(in-package #:mlisp)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Runtime path resolution (XDG Base Dir Spec + MLISP_HOME + --home flag)
;;;
;;; Priority (lowest → highest):
;;;   /etc/mlisp/                    compiled-in default
;;;   $XDG_CONFIG_HOME/mlisp/        XDG spec
;;;   ~/.config/mlisp/               XDG fallback when XDG_CONFIG_HOME unset
;;;   $MLISP_HOME                    env override
;;;   *mlisp-home-override*          set by --home CLI flag (highest)
;;; ─────────────────────────────────────────────────────────────────────────────

(defparameter *mlisp-home-override* nil
  "When non-nil, overrides all other home resolution (set by --home flag).")

(defparameter *state* nil "In-memory copy of the state database.")

(defun ensure-trailing-slash (s)
  "Return S with a trailing slash, or the empty string if S is nil/empty."
  (if (and s (> (length s) 0))
      (if (char= (char s (1- (length s))) #\/)
          s
          (concatenate 'string s "/"))
      nil))

(defun xdg-config-home ()
  "Return $XDG_CONFIG_HOME if set, else ~/.config/."
  (let ((xdg (sb-ext:posix-getenv "XDG_CONFIG_HOME")))
    (if (and xdg (> (length xdg) 0))
        (ensure-trailing-slash xdg)
        (let ((home (sb-ext:posix-getenv "HOME")))
          (when home
            (concatenate 'string home "/.config/"))))))

(defun mlisp-home ()
  "Resolve config directory using priority chain.
   Returns a pathname string with trailing slash."
  (or
   ;; 1. --home CLI flag (highest)
   (ensure-trailing-slash *mlisp-home-override*)
   ;; 2. MLISP_HOME env var
   (ensure-trailing-slash (sb-ext:posix-getenv "MLISP_HOME"))
   ;; 3. XDG: $XDG_CONFIG_HOME/mlisp/ or ~/.config/mlisp/
   (let ((xdg (xdg-config-home)))
     (when xdg
       (let ((p (concatenate 'string xdg "mlisp/")))
         ;; Only use XDG path if state.sexp actually exists there
         (when (probe-file (concatenate 'string p "state/state.sexp"))
           p))))
   ;; 4. Compiled-in default: directory of the running binary
   (directory-namestring
    (truename sb-ext:*runtime-pathname*))))

(defun state-path ()
  (merge-pathnames "state/state.sexp" (mlisp-home)))

(defun template-dir ()
  (merge-pathnames "templates/" (mlisp-home)))

(defun audit-path ()
  "Path to the append-only audit event log."
  (merge-pathnames "state/audit.sexp" (mlisp-home)))

(defun sendmail-path ()
  "Return the sendmail(8) binary path, from MLISP_SENDMAIL env or default."
  (or (sb-ext:posix-getenv "MLISP_SENDMAIL") "/usr/sbin/sendmail"))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; State I/O
;;; ─────────────────────────────────────────────────────────────────────────────

(defun load-state ()
  "Read state.sexp from (state-path) into *state*."
  (with-open-file (s (state-path) :direction :input
                                  :if-does-not-exist :error)
    (setf *state* (read s))))

(defun save-state ()
  "Persist *state* back to (state-path).
   Uses lowercase keyword printing for human readability and grep compatibility."
  (with-open-file (s (state-path) :direction :output
                                  :if-exists :supersede)
    (let ((*print-pretty*      t)
          (*print-case*        :downcase)
          (*print-readably*    nil)
          (*print-escape*      t))
      (write *state* :stream s)
      (terpri s))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; State accessors
;;; ─────────────────────────────────────────────────────────────────────────────

(defun find-list (list-id)
  "Return the plist for LIST-ID from state, or NIL."
  (find list-id (getf *state* :lists) :key (lambda (l) (getf l :id)) :test #'string=))

;;; Subscriber records are plists:
;;;   (:address "foo@bar.com"
;;;    :subscribed-at "2026-06-08T12:00:00"
;;;    :consent-method "email-subscribe-command")

(defun list-subscribers (list-id)
  "Return subscriber record list (plists) for LIST-ID."
  (getf (find-list list-id) :subscribers))

(defun subscriber-addresses (list-id)
  "Return flat list of subscriber email address strings for LIST-ID."
  (mapcar (lambda (r) (getf r :address)) (list-subscribers list-id)))

(defun subscriber-p (list-id address)
  "Return T if ADDRESS is subscribed to LIST-ID (case-insensitive)."
  (member (string-downcase address)
          (mapcar #'string-downcase (subscriber-addresses list-id))
          :test #'string=))

(defun iso8601-now ()
  "Return current UTC time as ISO-8601 string YYYY-MM-DDTHH:MM:SS."
  (multiple-value-bind (sec min hr day mon yr)
      (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0D"
            yr mon day hr min sec)))

(defun add-subscriber (list-id address)
  "Add ADDRESS to LIST-ID subscribers with consent metadata. No-op if present."
  (unless (subscriber-p list-id address)
    (let ((lst (find-list list-id)))
      (when lst
        (setf (getf lst :subscribers)
              (cons (list :address (string-downcase address)
                          :subscribed-at (iso8601-now)
                          :consent-method "email-subscribe-command")
                    (getf lst :subscribers)))))))

(defun remove-subscriber (list-id address)
  "Remove ADDRESS from LIST-ID subscribers (GDPR Art.17 erasure)."
  (let ((lst (find-list list-id)))
    (when lst
      (setf (getf lst :subscribers)
            (remove (string-downcase address)
                    (getf lst :subscribers)
                    :key  (lambda (r) (string-downcase (getf r :address)))
                    :test #'string=)))))

(defun list-postal-address (list-id)
  "Return the physical postal address for LIST-ID (CAN-SPAM § 7704(a)(5)(A))."
  (or (getf (find-list list-id) :postal-address)
      "Da Planet Security, 1207 Delaware Ave Ste 103, Wilmington DE 19806, USA"))

(defun list-privacy-url (list-id)
  "Return the privacy policy URL for LIST-ID."
  (or (getf (find-list list-id) :privacy-url)
      "https://dwightspencer.com/privacy"))

(defun list-request-address (list-id)
  "Return the -request command address for LIST-ID."
  (or (getf (find-list list-id) :request-address)
      (let ((drop (list-drop-address list-id)))
        ;; Derive: foo+bar@host -> foo+bar-request@host
        (if drop
            (let* ((at (position #\@ drop))
                   (local (subseq drop 0 at))
                   (domain (subseq drop at)))
              (concatenate 'string local "-request" domain))
            nil))))

(defun list-auto-subscribe-p (list-id)
  "Return T if the list has :auto-subscribe set to T."
  (getf (find-list list-id) :auto-subscribe))

(defun list-max-bounces (list-id)
  "Return the bounce threshold for LIST-ID."
  (or (getf (find-list list-id) :max-bounces) 5))

(defun subscriber-bounce-count (list-id address)
  "Return the bounce count for ADDRESS on LIST-ID."
  (let ((rec (find (string-downcase address)
                   (list-subscribers list-id)
                   :key (lambda (r) (string-downcase (getf r :address)))
                   :test #'string=)))
    (or (getf rec :bounce-count) 0)))

(defun increment-bounce (list-id address)
  "Increment bounce count for ADDRESS on LIST-ID. Returns new count."
  (let* ((lst (find-list list-id))
         (subs (getf lst :subscribers))
         (rec (find (string-downcase address) subs
                    :key (lambda (r) (string-downcase (getf r :address)))
                    :test #'string=)))
    (when rec
      (let ((new-count (1+ (or (getf rec :bounce-count) 0))))
        (setf (getf rec :bounce-count) new-count)
        (setf (getf rec :last-bounce) (iso8601-now))
        new-count))))

(defun clear-bounce (list-id address)
  "Reset bounce count for ADDRESS on LIST-ID."
  (let* ((lst (find-list list-id))
         (rec (find (string-downcase address)
                    (getf lst :subscribers)
                    :key (lambda (r) (string-downcase (getf r :address)))
                    :test #'string=)))
    (when rec
      (setf (getf rec :bounce-count) 0)
      (setf (getf rec :last-bounce) nil))))

(defparameter *process-mode* :normal
  "Processing mode: :normal, :request, or :bounce.")

(defparameter *metrics-path-override* nil
  "When non-nil, overrides the metrics file path.")

(defun metrics-path ()
  "Path to the Prometheus metrics file."
  (or *metrics-path-override*
      (merge-pathnames "metrics/mlisp.prom" (mlisp-home))))

(defun list-drop-address (list-id)
  "Return the canonical drop address for LIST-ID."
  (getf (find-list list-id) :drop-address))

(defun list-loop-header (list-id)
  "Return the X-Loop header field name for LIST-ID."
  (format nil "X-Loop-List-~:(~A~)" list-id))
