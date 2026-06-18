;;;; src/bugs.lisp -- mlisp-bugs: Debbugs-compatible email bug tracker
;;;;
;;;; Architecture decision: Maildir IS the database.
;;;; state.sexp holds ONLY :bug-counter + package config.
;;;; State is derived by scanning the archive -- exactly as Debbugs does.
;;;;
;;;; Reuses established patterns from requests.lisp:
;;;;   maildir-messages, read-message-headers, get-archived-message idiom

(in-package #:mlisp)

;;; Forward declarations (pattern from distrib.lisp)
(declaim (special *state*))

;;; ─── Macro: with-bug-pkg ─────────────────────────────────────────────────────
;;; DRY wrapper used by all process-* functions and admin commands.

(defmacro with-bug-pkg ((entry-var pkg-expr) &body body)
  "Load state, find package PKG-EXPR, bind to ENTRY-VAR, or error."
  (let ((pkg-sym (gensym "pkg")))
    `(progn
       (load-state)
       (let* ((,pkg-sym ,pkg-expr)
              (,entry-var (find-bugs-package ,pkg-sym)))
         (unless ,entry-var
           (format *error-output* "mlisp-bugs: unknown package ~A~%" ,pkg-sym)
           (return-from ,(first body) 1))
         ,@(rest body)))))

;;; Simpler variant when we already have the entry
(defmacro with-existing-bug ((pkg bug-id) &body body)
  "Verify bug BUG-ID exists in PKG, then execute BODY."
  `(unless (bug-exists-p ,pkg ,bug-id)
     (format *error-output* "mlisp-bugs: bug #~A not found in ~A~%" ,bug-id ,pkg)
     (return-from ,(first body) 1))
  `(progn ,@body))

;;; ─── Package config (only mutable state: counter + addresses) ───────────────

(defun bugs-packages ()
  (or (getf *state* :bugs-packages) '()))

(defun find-bugs-package (pkg)
  (find pkg (bugs-packages)
        :key (lambda (p) (getf p :package))
        :test #'string=))

(defun bugs-package-counter (pkg)
  (or (getf (find-bugs-package pkg) :bug-counter) 0))

(defun bugs-next-id (pkg)
  (let* ((entry (find-bugs-package pkg))
         (n     (1+ (or (getf entry :bug-counter) 0))))
    (if (member :bug-counter entry)
        (setf (getf entry :bug-counter) n)
        (nconc entry (list :bug-counter n)))
    (save-state)
    n))

(defun add-bugs-package (pkg submit-addr &key owner-address (default-severity "normal"))
  (load-state)
  (when (find-bugs-package pkg)
    (error "Package ~A already registered" pkg))
  (let ((entry (list :package          pkg
                     :submit-address   submit-addr
                     :owner-address    (or owner-address "")
                     :default-severity default-severity
                     :bug-counter      0)))
    (if (member :bugs-packages *state*)
        (nconc (getf *state* :bugs-packages) (list entry))
        (nconc *state* (list :bugs-packages (list entry))))
    (save-state)
    entry))

;;; ─── Maildir (reuses maildir-write from maildir.lisp + patterns from requests.lisp)

(defun bugs-list-id (pkg)
  "Maildir list-id for PKG bug archive: PKG-bugs convention.
   Reuses maildir-path/maildir-messages from requests.lisp."
  (format nil "~A-bugs" pkg))



(defun bugs-archive (pkg raw-msg)
  "Write RAW-MSG to Maildir using maildir-write and bugs-list-id convention.
   Under (maildir-root): $MAILDIR/lists/<pkg>-bugs/ if $MAILDIR is set,
   else $MLISP_HOME/state/maildir/<pkg>-bugs/."
  (maildir-write
   (uiop:ensure-directory-pathname
    (merge-pathnames (format nil "~A/" (bugs-list-id pkg)) (maildir-root)))
   raw-msg))

(defun bug-message->string (path)
  "Read full message from PATH as string (pattern from get-archived-message)."
  (ignore-errors
    (with-open-file (s path)
      (let* ((buf (make-string (* 256 1024)))
             (len (read-sequence buf s)))
        (subseq buf 0 len)))))

;;; ─── Derive state (Maildir IS the database) ──────────────────────────────────

(defun bugs-parse-pseudo-headers (content)
  "Extract Severity:, Tags:, Owner: from message body content string.
   Returns alist. Stops at blank line. Uses same approach as search-maildir."
  (let ((result '()) (in-body nil))
    (dolist (line (split-string content #\Newline))
      (let ((l (string-trim '(#\Return #\Space) line)))
        (cond
          (in-body
           (let ((colon (position #\: l)))
             (when (and colon (> colon 0))
               (let ((k (string-trim " " (subseq l 0 colon)))
                     (v (string-trim " " (subseq l (1+ colon)))))
                 (when (member k '("Severity" "Tags" "Owner")
                               :test #'string-equal)
                   (push (cons k v) result))))))
          ((zerop (length l)) (setf in-body t)))))
    (nreverse result)))

(defun bugs-parse-control-lines (content)
  "Extract control commands (severity N X, tags N +/- T, etc.) from content.
   Returns list of (cmd num . rest-args)."
  (let ((cmds '()))
    (dolist (line (split-string content #\Newline))
      (let* ((l     (string-trim '(#\Return #\Space) line))
             (words (remove "" (split-string l #\Space) :test #'string=)))
        (when (>= (length words) 2)
          (let ((cmd (string-downcase (first words)))
                (num (parse-integer (second words) :junk-allowed t)))
            (when (and num
                       (member cmd '("severity" "tags" "owner" "retitle"
                                     "close" "reopen" "forwarded"
                                     "block" "unblock" "merge")
                               :test #'string=))
              (push (list* cmd num (cddr words)) cmds))))))
    (nreverse cmds)))

(defun bugs-derive-state (pkg bug-id)
  "Derive current state for BUG-ID by scanning PKG Maildir archive.
   Returns plist or nil. Scans all messages for control commands;
   uses Bug#N: subject messages for initial state and [CLOSED] status."
  (let ((id-prefix (format nil "Bug#~A:" bug-id))
        (title nil) (severity "normal") (status :open)
        (tags '()) (owner nil) (reported-by nil) (date nil))
    (dolist (path (maildir-messages (bugs-list-id pkg)))
      (let* ((hdrs    (read-message-headers path))
             (subj    (or (cdr (assoc "Subject" hdrs :test #'string-equal)) ""))
             (from    (or (cdr (assoc "From"    hdrs :test #'string-equal)) ""))
             (dval    (or (cdr (assoc "Date"    hdrs :test #'string-equal)) ""))
             (content (bug-message->string path)))
        ;; Scan ALL messages for control commands (not just Bug#N: ones)
        (when content
          (dolist (cmd (bugs-parse-control-lines content))
            (let ((verb (first cmd))
                  (num  (second cmd))
                  (args (cddr cmd)))
              (when (= num bug-id)
                (cond
                  ((string= verb "severity") (setf severity (or (first args) severity)))
                  ((and (string= verb "tags") args (rest args))
                   (let ((op (first args)) (tag (second args)))
                     (cond ((string= op "+") (pushnew tag tags :test #'string=))
                           ((string= op "-")
                            (setf tags (remove tag tags :test #'string=))))))
                  ((string= verb "owner")   (setf owner (first args)))
                  ((string= verb "retitle")
                   (setf title (string-trim " " (format nil "~{~A ~}" args))))
                  ((string= verb "close")   (setf status :closed))
                  ((string= verb "reopen")  (setf status :open)))))))
        ;; Bug#N: subject messages: initial state + [CLOSED] marker
        (when (search id-prefix subj :test #'char-equal)
          (unless title
            (setf title (string-trim " " (subseq subj (length id-prefix)))
                  reported-by from
                  date dval)
            (let ((pseudo (when content (bugs-parse-pseudo-headers content))))
              (let ((sev (cdr (assoc "Severity" pseudo :test #'string-equal)))
                    (tgs (cdr (assoc "Tags"     pseudo :test #'string-equal)))
                    (own (cdr (assoc "Owner"    pseudo :test #'string-equal))))
                (when sev (setf severity sev))
                (when tgs (setf tags (remove "" (split-string tgs #\Space)
                                             :test #'string=)))
                (when own (setf owner own)))))
          (when (search "[CLOSED]" subj :test #'char-equal)
            (setf status :closed)))))
    (when title
      (list :id bug-id :title title :severity severity :status status
            :tags tags :owner owner :reported-by reported-by :date date))))



(defun bug-exists-p (pkg bug-id)
  (not (null (bugs-derive-state pkg bug-id))))

;;; ─── Message assembly macro ──────────────────────────────────────────────────

(defun assemble-message (headers body-lines)
  "Build RFC 2822 message string from headers alist and body lines list."
  (with-output-to-string (s)
    (dolist (h headers)
      (format s "~A: ~A~%" (car h) (cdr h)))
    (terpri s)
    (dolist (line body-lines)
      (write-line line s))))

;;; ─── Pseudo-header injection ─────────────────────────────────────────────────

(defun inject-pseudo-headers (headers body-lines bug-id pkg severity)
  "Prepend Debbugs pseudo-header block to BODY-LINES.
   Header keys from the parser are uppercase (FROM, SUBJECT, MESSAGE-ID)."
  (let ((from   (or (cdr (assoc "FROM"       headers :test #'string=)) ""))
        (msg-id (or (cdr (assoc "MESSAGE-ID" headers :test #'string=))
                    (format nil "<~A.~A@mlisp>" (get-universal-time) (random 99999))))
        (subj   (or (cdr (assoc "SUBJECT"    headers :test #'string=)) "")))
    (append (list (format nil "Bug#~A: ~A" bug-id subj)
                  (format nil "Package: ~A" pkg)
                  (format nil "Severity: ~A" severity)
                  (format nil "Reported-by: ~A" from)
                  (format nil "Date: ~A" (iso8601-now))
                  (format nil "Message-ID: ~A" msg-id)
                  "")
            body-lines)))

;;; ─── Control command parser ──────────────────────────────────────────────────

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defstruct control-result commands unknown quit-seen))

(defun parse-control-body (body-lines)
  (let ((commands '()) (unknown '()) (quit nil))
    (dolist (line body-lines)
      (unless quit
        (let ((l (string-trim '(#\Space #\Tab #\Return) line)))
          (cond
            ((zerop (length l)))
            ((char= (char l 0) #\#))
            ((string-equal l "quit") (setf quit t))
            (t
             (let ((words (remove "" (split-string l #\Space) :test #'string=)))
               (when words
                 (let ((cmd (string-downcase (first words))))
                   (if (member cmd '("severity" "tags" "close" "reopen" "retitle"
                                     "owner" "noowner" "forwarded" "block" "unblock"
                                     "merge" "unmerge" "found" "fixed" "reassign")
                               :test #'string=)
                       (push (cons cmd (rest words)) commands)
                       (push l unknown))))))))))
    (make-control-result :commands (nreverse commands)
                         :unknown  (nreverse unknown)
                         :quit-seen quit)))

;;; ─── Distribution ────────────────────────────────────────────────────────────

(defun bugs-distribute (pkg headers body-lines &key extra-recipients)
  "Send bug message to owner + extra-recipients.
   Uses sendmail from mta.lisp (established pattern)."
  (let* ((entry      (find-bugs-package pkg))
         (owner      (or (getf entry :owner-address) ""))
         (recipients (remove-if (lambda (r) (or (null r) (zerop (length r))))
                                 (cons owner extra-recipients))))
    (sendmail recipients (assemble-message headers body-lines))))

;;; ─── Four processing modes ───────────────────────────────────────────────────

(defun bugs-process-submit (pkg headers body-lines)
  (load-state)
  (let* ((entry    (find-bugs-package pkg))
         (bug-id   (bugs-next-id pkg))
         (subj     (or (cdr (assoc "SUBJECT" headers :test #'string=)) "(no subject)"))
         (from     (or (cdr (assoc "FROM"    headers :test #'string=)) ""))
         (severity (or (loop for line in body-lines
                             for colon = (position #\: line)
                             when (and colon (string-equal "Severity"
                                       (string-trim " " (subseq line 0 colon))))
                             return (string-trim " " (subseq line (1+ colon))))
                       (getf entry :default-severity) "normal"))
         (new-body (inject-pseudo-headers headers body-lines bug-id pkg severity))
         (new-hdrs (mapcar (lambda (h)
                             (if (string-equal (car h) "SUBJECT")
                                 (cons "Subject" (format nil "Bug#~A: ~A" bug-id subj))
                                 h))
                           headers))
         (raw-msg  (assemble-message new-hdrs new-body)))
    (bugs-archive pkg raw-msg)
    (bugs-distribute pkg new-hdrs new-body :extra-recipients (list from))
    (audit-append (list :event :bug-submitted :package pkg :id bug-id
                        :from from :severity severity))
    bug-id))

(defun bugs-process-append (pkg bug-id headers body-lines)
  (load-state)
  (unless (bug-exists-p pkg bug-id)
    (format *error-output* "mlisp-bugs: bug #~A not found in ~A~%" bug-id pkg)
    (return-from bugs-process-append 1))
  (let ((from (or (cdr (assoc "FROM" headers :test #'string=)) "")))
    (bugs-archive pkg (assemble-message headers body-lines))
    (bugs-distribute pkg headers body-lines :extra-recipients (list from))
    (audit-append (list :event :bug-reply :package pkg :id bug-id :from from))
    0))

(defun bugs-process-close (pkg bug-id headers body-lines)
  (load-state)
  (unless (bug-exists-p pkg bug-id)
    (format *error-output* "mlisp-bugs: bug #~A not found in ~A~%" bug-id pkg)
    (return-from bugs-process-close 1))
  (let* ((state    (bugs-derive-state pkg bug-id))
         (title    (getf state :title))
         (reporter (getf state :reported-by))
         (from     (or (cdr (assoc "FROM" headers :test #'string=)) ""))
         (new-hdrs (mapcar (lambda (h)
                             (if (string-equal (car h) "SUBJECT")
                                 (cons "Subject"
                                       (format nil "[CLOSED] Bug#~A: ~A" bug-id title))
                                 h))
                           headers))
         (new-body (append body-lines
                           (list "" (format nil "-- Bug#~A closed by ~A" bug-id from)))))
    (bugs-archive pkg (assemble-message new-hdrs new-body))
    (bugs-distribute pkg new-hdrs new-body
                     :extra-recipients (list reporter from))
    (audit-append (list :event :bug-closed :package pkg :id bug-id :from from))
    0))

(defun bugs-process-control (pkg headers body-lines)
  (load-state)
  (let* ((from   (or (cdr (assoc "FROM" headers :test #'string=)) ""))
         (result (parse-control-body body-lines))
         (ack    '()))
    (dolist (cmd (control-result-commands result))
      (let* ((verb (car cmd))
             (args (cdr cmd))
             (num  (when args (parse-integer (first args) :junk-allowed t))))
        (when num
          (cond
            ((string= verb "close")
             (bugs-process-close pkg num
               (list (cons "FROM" from) (cons "SUBJECT" "") (cons "DATE" (iso8601-now)))
               (list (format nil "Closed via control by ~A" from))))
            ((string= verb "reopen")
             (bugs-archive pkg
               (format nil "From: ~A~%Subject: [REOPEN] Bug#~A~%Date: ~A~%~%Reopened.~%"
                       from num (iso8601-now))))
            (t
             (bugs-archive pkg
               (format nil "From: ~A~%Subject: Re: Bug#~A (control)~%Date: ~A~%~%~A ~A~%"
                       from num (iso8601-now) verb (format nil "~{~A ~}" args)))))
          (push (format nil "  ~A ~A -- ok" verb num) ack))))
    (sendmail (list from)
              (format nil "From: mlisp-bugs~%To: ~A~%Subject: control processed~%~%~{~A~%~}"
                      from (nreverse ack)))
    (audit-append (list :event :control-processed :package pkg :from from))
    0))

;;; ─── Report generation (#70) ─────────────────────────────────────────────────

(defun bugs-generate-report (pkg &key open-only closed-only severity-filter tag-filter)
  (load-state)
  (let* ((bugs (loop for n from 1 to (bugs-package-counter pkg)
                     for s = (bugs-derive-state pkg n)
                     when s collect s))
         (bugs (remove-if-not
                (lambda (s)
                  (and (or (not open-only)   (eq (getf s :status) :open))
                       (or (not closed-only) (eq (getf s :status) :closed))
                       (or (null severity-filter)
                           (string-equal (getf s :severity) severity-filter))
                       (or (null tag-filter)
                           (member tag-filter (getf s :tags) :test #'string-equal))))
                bugs))
         (open   (remove-if-not (lambda (s) (eq (getf s :status) :open))   bugs))
         (closed (remove-if-not (lambda (s) (eq (getf s :status) :closed)) bugs)))
    (with-output-to-string (s)
      (format s "Bug report for ~A -- ~A~%~%" pkg (iso8601-now))
      (when (or (not closed-only) open-only)
        (format s "Open bugs (~A):~%" (length open))
        (if open
            (dolist (b open)
              (format s "  #~3D [~9A] ~A~%" (getf b :id) (getf b :severity) (getf b :title)))
            (format s "  (none)~%"))
        (terpri s))
      (when (or closed-only (not open-only))
        (format s "Closed bugs (~A):~%" (length closed))
        (if closed
            (dolist (b closed) (format s "  #~3D ~A~%" (getf b :id) (getf b :title)))
            (format s "  (none)~%"))
        (terpri s))
      (format s "Total: ~A open, ~A closed~%" (length open) (length closed)))))
