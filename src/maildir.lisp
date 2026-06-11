;;;; src/maildir.lisp — Maildir archive writer
;;;;
;;;; Writes distributed messages to a Maildir spool for notmuch/mutt indexing.
;;;; mlisp only writes; the user wires their own indexer via cron or inotify.
;;;; Strictly read-from-Maildir is the user's concern.

(in-package #:mlisp)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Maildir filename generator (Maildir++ compatible)
;;; ─────────────────────────────────────────────────────────────────────────────

(defun maildir-unique-name ()
  "Generate a unique Maildir filename per the spec:
   <timestamp>.<pid>.<hostname>"
  (let* ((ts   (get-universal-time))
         ;; sb-posix may not be loaded; try to require it gracefully
         (pid  (or (ignore-errors
                     (progn (require :sb-posix)
                            (funcall (find-symbol "GETPID" :sb-posix))))
                   ;; Read PID from /proc/self on Linux (no sb-posix needed)
                   (or (ignore-errors
                         (with-open-file (s "/proc/self/status")
                           (loop for line = (read-line s nil nil)
                                 while line
                                 when (and (> (length line) 4)
                                           (string= "Pid:" (subseq line 0 4)))
                                 return (parse-integer line :start 4
                                                        :junk-allowed t))))
                       (random 999983))))
         (host (or (ignore-errors
                     (string-trim '(#\Space #\Newline #\Return)
                       (with-output-to-string (s)
                         (sb-ext:run-program "/bin/hostname" '()
                           :output s :error nil :wait t))))
                   "localhost")))
    (format nil "~A.~A.~A" ts pid host)))

(defun ensure-maildir (path)
  "Create Maildir subdirectory structure at PATH if absent."
  (dolist (sub '("new" "cur" "tmp"))
    (ensure-directories-exist
     (merge-pathnames (format nil "~A/" sub)
                      (uiop:ensure-directory-pathname path)))))

(defun maildir-write (maildir-path message-string)
  "Write MESSAGE-STRING to MAILDIR-PATH/new/<unique-name>.
   Creates the Maildir structure if absent.
   Uses tmp/ for atomic write then renames to new/."
  (ignore-errors
    (let* ((dir      (uiop:ensure-directory-pathname maildir-path))
           (fname    (maildir-unique-name))
           (tmp-path (merge-pathnames (format nil "tmp/~A" fname) dir))
           (new-path (merge-pathnames (format nil "new/~A" fname) dir)))
      (ensure-maildir dir)
      (with-open-file (s tmp-path :direction :output
                                  :if-does-not-exist :create
                                  :if-exists :supersede)
        (write-string message-string s))
      (rename-file tmp-path new-path)
      new-path)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Integration hook called from distribute-message
;;; ─────────────────────────────────────────────────────────────────────────────

(defun maybe-archive-to-maildir (list-id headers body-lines)
  "If the list has a :maildir-path configured, write the message there.
   Uses the pre-footer body for a clean archive copy."
  (let ((mdir (getf (find-list list-id) :maildir-path)))
    (when (and mdir (stringp mdir) (> (length mdir) 0))
      (let ((msg (with-output-to-string (s)
                   (dolist (h headers)
                     (format s "~A: ~A~%" (car h) (cdr h)))
                   (terpri s)
                   (dolist (line body-lines)
                     (write-line line s)))))
        (maildir-write mdir msg)))))
