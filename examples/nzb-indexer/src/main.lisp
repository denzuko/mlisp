;;;; src/main.lisp -- batch Maildir processor for the NZB release indexer
;;;;
;;;; Cron schedule: */5 * * * *
;;;; fetchmail pulls -distrib list messages into $MAILDIR/new/.
;;;; This binary reads all unread messages, indexes new segments,
;;;; serves get-nzb commands, and announces completed releases.

(in-package #:com.dwightaspencer.nzb-indexer)

;;; ── Environment ──────────────────────────────────────────────────────────

(defun getenv (name &optional default)
  (or (sb-ext:posix-getenv name) default))

(defun service-address ()
  (getenv "NZB_SERVICE_ADDRESS" "distrib-nzb@lists.example.com"))

(defun announce-address ()
  (getenv "NZB_ANNOUNCE_ADDRESS" "releases-announce@lists.example.com"))

(defun sendmail-path ()
  (getenv "MLISP_SENDMAIL" "/usr/sbin/sendmail"))

(defun index-path ()
  (pathname (getenv "NZB_INDEX_PATH"
                    (namestring (merge-pathnames ".nzb-index.sexp"
                                                (user-homedir-pathname))))))

;;; ── Maildir ──────────────────────────────────────────────────────────────

(defun ensure-trailing-slash (str)
  (if (char= (char str (1- (length str))) #\/) str
      (concatenate 'string str "/")))

(defun maildir-new (maildir)
  "Return list of pathnames of all files in MAILDIR/new/."
  (let* ((new-str (concatenate 'string (ensure-trailing-slash maildir) "new/"))
         (new-pn  (pathname new-str)))
    (when (probe-file new-pn)
      (directory (make-pathname :directory (pathname-directory new-pn)
                                :name :wild :type :wild)))))

(defun mark-read (pathname)
  "Move pathname from new/ to cur/ with :2, flags suffix."
  (let* ((filename (file-namestring pathname))
         (base     (let ((colon (position #\: filename)))
                     (if colon (subseq filename 0 colon) filename)))
         (cur-dir  (make-pathname
                    :directory (append (butlast (pathname-directory pathname))
                                       (list "cur"))))
         (cur-path (merge-pathnames (format nil "~A:2," base) cur-dir)))
    (ensure-directories-exist cur-dir)
    (rename-file pathname cur-path)))

(defun slurp-file (path)
  (with-open-file (s path :external-format :utf-8)
    (let ((buf (make-string (file-length s))))
      (read-sequence buf s)
      buf)))

;;; ── Reply ────────────────────────────────────────────────────────────────

(defun send-nzb-reply (to from subject in-reply-to nzb-string)
  "Send an NZB reply with the XML attached."
  (let ((proc (sb-ext:run-program (sendmail-path) (list "-t")
                                   :input :stream :wait nil)))
    (let ((in (sb-ext:process-input proc)))
      (format in "From: ~A~%"          from)
      (format in "To: ~A~%"            to)
      (format in "Subject: Re: ~A~%"   subject)
      (when in-reply-to
        (format in "In-Reply-To: ~A~%" in-reply-to)
        (format in "References: ~A~%"  in-reply-to))
      (format in "X-Loop: ~A~%"        from)
      (format in "MIME-Version: 1.0~%")
      (format in "Content-Type: application/x-nzb; name=\"release.nzb\"~%")
      (format in "Content-Disposition: attachment; filename=\"release.nzb\"~%")
      (format in "~%")
      (write-string nzb-string in)
      (close in))
    (sb-ext:process-wait proc)))

(defun send-error-reply (to from subject in-reply-to message)
  "Send a plain-text error reply."
  (let ((proc (sb-ext:run-program (sendmail-path) (list "-t")
                                   :input :stream :wait nil)))
    (let ((in (sb-ext:process-input proc)))
      (format in "From: ~A~%" from)
      (format in "To: ~A~%"   to)
      (format in "Subject: Re: ~A~%" subject)
      (when in-reply-to
        (format in "In-Reply-To: ~A~%" in-reply-to)
        (format in "References: ~A~%"  in-reply-to))
      (format in "X-Loop: ~A~%"        from)
      (format in "Content-Type: text/plain; charset=utf-8~%")
      (format in "~%")
      (format in "~A~%" message)
      (close in))
    (sb-ext:process-wait proc)))

(defun send-announce (to from release-title idx)
  "Send a release announcement to the announce list."
  (let ((body (build-announce-body idx release-title))
        (proc (sb-ext:run-program (sendmail-path) (list "-t")
                                   :input :stream :wait nil)))
    (let ((in (sb-ext:process-input proc)))
      (format in "From: ~A~%"     from)
      (format in "To: ~A~%"       to)
      (format in "Subject: [new release] ~A~%" release-title)
      (format in "X-Loop: ~A~%"   from)
      (format in "Precedence: list~%")
      (format in "Content-Type: text/plain; charset=utf-8~%")
      (format in "~%")
      (write-string (or body "") in)
      (close in))
    (sb-ext:process-wait proc)))

;;; ── Message processing ───────────────────────────────────────────────────

(defun process-one (path idx service-addr)
  "Process one Maildir message.
   Returns (values status newly-completed-title-or-nil)."
  (handler-case
      (let* ((raw     (slurp-file path))
             (headers (mime:parse-headers (make-string-input-stream raw)))
             (parsed  (mime:parse-mime raw))
             (body    (or (mime:content parsed) "")))

        ;; Skip our own replies
        (when (x-loop-p headers service-addr)
          (mark-read path)
          (return-from process-one (values :skipped nil)))

        (let ((from       (cdr (assoc :from       headers)))
              (subject    (or (cdr (assoc :subject    headers)) ""))
              (message-id (cdr (assoc :message-id headers))))

          (cond
            ;; ── get-nzb command ─────────────────────────────────────────
            ((get-nzb-command-p headers service-addr)
             (let* ((title (extract-nzb-title headers))
                    (nzb   (when title (build-nzb idx title))))
               (if nzb
                   (send-nzb-reply from service-addr subject message-id nzb)
                   (send-error-reply
                    from service-addr subject message-id
                    (format nil "Release not found: ~A~%~
                                 Use 'list-releases' for available titles."
                            title))))
             (mark-read path)
             (values :served nil))

            ;; ── distrib segment ─────────────────────────────────────────
            ((distrib-message-p headers)
             (let ((completed nil))
               (multiple-value-bind (filename part total)
                   (parse-distrib-subject subject)
                 (when (and filename part total)
                   (let ((title (release-title-from-filename filename)))
                     (add-segment idx
                       :title      title
                       :filename   filename
                       :message-id (or message-id
                                       (format nil "<unknown-~A>" (get-universal-time)))
                       :part       part
                       :total      total
                       :size       (length (the string body))
                       :offset     (* (1- part) 750000))
                     ;; Check if this segment completed the release
                     (let ((release (find-release idx title)))
                       (when (and release (release-complete-p release))
                         (setf completed title))))))
               (mark-read path)
               (values :indexed completed)))

            ;; ── unrecognised ─────────────────────────────────────────────
            (t
             (mark-read path)
             (values :skipped nil)))))
    (error (e)
      (format *error-output* "nzb-indexer: error processing ~A: ~A~%"
              (file-namestring path) e)
      (ignore-errors (mark-read path))
      (values :error nil))))

;;; ── Main ─────────────────────────────────────────────────────────────────

(defun main ()
  "Batch process all unread messages in $MAILDIR/new/."
  (let* ((maildir      (getenv "MAILDIR"
                                (namestring (merge-pathnames "Maildir/"
                                             (user-homedir-pathname)))))
         (service-addr (service-address))
         (announce-addr (announce-address))
         (idx-path     (index-path))
         (idx          (load-index idx-path))
         (messages     (maildir-new maildir))
         (newly-completed '()))

    (when messages
      (let ((indexed 0) (served 0) (skipped 0) (errors 0)
            (newly-completed '()))
        (dolist (msg messages)
          (multiple-value-bind (status completed)
              (process-one msg idx service-addr)
            (case status
              (:indexed  (incf indexed))
              (:served   (incf served))
              (:skipped  (incf skipped))
              (:error    (incf errors)))
            (when completed
              (pushnew completed newly-completed :test #'string=))))

        ;; Persist updated index
        (save-index idx idx-path)

        ;; Announce newly completed releases
        (dolist (title newly-completed)
          (send-announce announce-addr service-addr title idx))

        (format *error-output*
                "nzb-indexer: ~A indexed, ~A served, ~A skipped, ~A errors~%"
                indexed served skipped errors))))
  (sb-ext:exit :code 0))
