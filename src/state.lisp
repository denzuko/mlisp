;;;; src/state.lisp — Runtime paths, state I/O, subscriber accessors
;;;; CAN-SPAM § 7704 / GDPR Art.7/17/30 data layer

(in-package #:mlisp)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Constants
;;; ─────────────────────────────────────────────────────────────────────────────

(defun mlisp-home ()
  "Return the runtime base directory, from MLISP_HOME env or binary location."
  (let ((env (sb-ext:posix-getenv "MLISP_HOME")))
    (if (and env (> (length env) 0))
        (if (char= (char env (1- (length env))) #\/)
            env
            (concatenate 'string env "/"))
        (directory-namestring
         (truename sb-ext:*runtime-pathname*)))))

(defun state-path ()
  (merge-pathnames "state/state.sexp" (mlisp-home)))

(defun template-dir ()
  (merge-pathnames "templates/" (mlisp-home)))

(defun sendmail-path ()
  "Return the sendmail(8) binary path, from MLISP_SENDMAIL env or default."
  (or (sb-ext:posix-getenv "MLISP_SENDMAIL") "/usr/sbin/sendmail"))

(defparameter *state* nil "In-memory copy of the state database.")

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

(defun list-drop-address (list-id)
  "Return the canonical drop address for LIST-ID."
  (getf (find-list list-id) :drop-address))

(defun list-loop-header (list-id)
  "Return the X-Loop header field name for LIST-ID."
  (format nil "X-Loop-List-~:(~A~)" list-id))
