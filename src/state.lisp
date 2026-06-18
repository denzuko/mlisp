;;;; src/state.lisp — Runtime paths, state I/O, subscriber accessors
;;;; CAN-SPAM § 7704 / GDPR Art.7/17/30 data layer

(in-package #:mlisp)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Runtime path resolution (XDG Base Dir Spec + MLISP_HOME + --home flag)
;;;
;;; Priority (highest → lowest):
;;;   *mlisp-home-override*          set by --home CLI flag (highest)
;;;   $MLISP_HOME                    env override
;;;   $XDG_CONFIG_HOME/mlisp/        XDG spec (or ~/.config/mlisp/ fallback;
;;;                                  ~ resolves via $HOME, falling back to
;;;                                  (user-homedir-pathname) i.e. passwd/PAM
;;;                                  when $HOME is unset -- see
;;;                                  xdg-config-home)
;;;   /etc/mlisp/                    system-wide fallback for service
;;;                                  accounts (e.g. MTA users) with no
;;;                                  initialized XDG config
;;;   directory of running binary    last-resort compiled-in default
;;;
;;; `mlisp-admin init` (cmd-init) does NOT use this chain to pick its
;;; *target* directory when none of the above are explicitly set --
;;; see cmd-init in admin.lisp for the bootstrap logic, which targets
;;; XDG (or /etc/mlisp as a last resort) unconditionally so that this
;;; chain's XDG/etc probe-file checks succeed on every subsequent run.
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
  "Return $XDG_CONFIG_HOME if set, else ~/.config/.
   For the home directory, $HOME takes precedence per the XDG Base
   Directory spec, but falls back to (user-homedir-pathname) -- which
   consults the passwd database via the OS -- when $HOME is unset.
   This matters under cron/systemd units without PAMName=, where $HOME
   is frequently unset even though the account has a valid passwd entry."
  (let ((xdg (sb-ext:posix-getenv "XDG_CONFIG_HOME")))
    (if (and xdg (> (length xdg) 0))
        (ensure-trailing-slash xdg)
        (let ((home (or (sb-ext:posix-getenv "HOME")
                         (ignore-errors (namestring (user-homedir-pathname))))))
          (when (and home (> (length home) 0))
            (concatenate 'string (ensure-trailing-slash home) ".config/"))))))

(defun maildir-root ()
  "Return the root directory under which per-list Maildir archives live.

   Resolution order:
     1. $MAILDIR (Maildir-format mail spool root) -- the POSIX/
        freedesktop.org convention honored by smartlist, procmail,
        debbugs, and notmuch as the FIRST place to look. Lists live at
        $MAILDIR/lists/<list-id>/.
     2. $MLISP_HOME/state/maildir/ -- fallback when $MAILDIR is unset,
        so mlisp's internal archive (search/index/get, mlisp-bugs) keeps
        working out of the box with zero environment configuration.

   $MAIL (the mbox-format equivalent) is not consulted here: mlisp only
   ever writes Maildir-format archives, never mbox."
  (let ((maildir (sb-ext:posix-getenv "MAILDIR")))
    (if (and maildir (> (length maildir) 0))
        (concatenate 'string (ensure-trailing-slash maildir) "lists/")
        (concatenate 'string (mlisp-home) "state/maildir/"))))

(defun mlisp-init-target ()
  "Resolve the directory `mlisp-admin init` should create/populate when
   no --dir flag is given.

   Unlike mlisp-home, this does NOT require state/state.sexp to already
   exist at the XDG (or /etc/mlisp) path -- init's entire job is to
   create it there. This is the fix for the XDG bootstrap chicken-and-egg
   problem: mlisp-home's priority-3 XDG branch only returns the XDG path
   once state.sexp exists there, which init can never satisfy on a first
   run if it instead falls through to mlisp-home's lower priorities.

   --home/MLISP_HOME (explicit overrides) are honored as-is, since they
   carry no such existence requirement. Otherwise targets XDG
   unconditionally, or /etc/mlisp/ if no home directory is resolvable at
   all (xdg-config-home returns nil -- e.g. a minimal service account
   with neither $HOME nor a passwd entry)."
  (or
   (ensure-trailing-slash *mlisp-home-override*)
   (ensure-trailing-slash (sb-ext:posix-getenv "MLISP_HOME"))
   (let ((xdg (xdg-config-home)))
     (when xdg (concatenate 'string xdg "mlisp/")))
   "/etc/mlisp/"))

(defun mlisp-home ()
  "Resolve config directory using priority chain (see header comment).
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
   ;; 4. /etc/mlisp/ -- system-wide fallback for service accounts
   (when (probe-file "/etc/mlisp/state/state.sexp")
     "/etc/mlisp/")
   ;; 5. Compiled-in default: directory of the running binary
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
  "Return flat list of active (non-NOMAIL) subscriber email addresses for LIST-ID."
  (mapcar (lambda (r) (getf r :address))
          (remove-if (lambda (r) (getf r :nomail))
                     (list-subscribers list-id))))

(defun subscriber-p (list-id address)
  "Return T if ADDRESS is subscribed to LIST-ID (case-insensitive).
   Includes :nomail subscribers — they can still post, just not receive."
  (let ((addr-lc (string-downcase address)))
    (some (lambda (sub)
            (string= addr-lc
                     (string-downcase (or (getf sub :address) ""))))
          (list-subscribers list-id))))

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



;;; ─────────────────────────────────────────────────────────────────────────────
;;; Namespace and subgroup accessors
;;; ─────────────────────────────────────────────────────────────────────────────

(defparameter *known-subgroups*
  '("discuss" "announce" "devel" "distrib" "request"
    "owner" "security" "commits" "users")
  "Known subgroup suffixes in the namespace-subgroup convention.")

(defun list-subgroup (list-id)
  "Return the :subgroup keyword for LIST-ID, or derive it from the suffix."
  (or (getf (find-list list-id) :subgroup)
      ;; Derive from suffix: mlisp-discuss → :discuss
      (let ((id (string-downcase list-id)))
        (dolist (sg *known-subgroups*)
          (when (and (> (length id) (length sg))
                     (string= (subseq id (- (length id) (length sg))) sg)
                     (char= (char id (- (length id) (length sg) 1)) #\-))
            (return (intern (string-upcase sg) :keyword)))))))

(defun list-namespace (list-id)
  "Return the namespace prefix of LIST-ID (everything before the last -subgroup).
   e.g. mlisp-discuss → mlisp, mlisp-devel → mlisp."
  (let ((sg (list-subgroup list-id)))
    (when sg
      (let* ((suffix (string-downcase (symbol-name sg)))
             (id     (string-downcase list-id))
             (cut    (- (length id) (length suffix) 1)))
        (when (>= cut 0)
          (subseq id 0 cut))))))

(defun namespace-siblings (list-id)
  "Return all list records sharing the same namespace as LIST-ID."
  (let ((ns (list-namespace list-id)))
    (when (and ns *state*)
      (remove-if-not
       (lambda (lst)
         (let ((sibling-ns (list-namespace (getf lst :id))))
           (and sibling-ns (string= sibling-ns ns))))
       (getf *state* :lists)))))

(defun list-request-address (list-id)
  "Return the -request address for LIST-ID.
   Prefers stored :request-address; falls back to finding the -request sibling."
  (or (getf (find-list list-id) :request-address)
      ;; Find -request sibling in the same namespace
      (let ((sibling (find-if (lambda (lst)
                                (eq (list-subgroup (getf lst :id)) :request))
                              (namespace-siblings list-id))))
        (when sibling (getf sibling :drop-address)))
      ;; Last resort: derive from drop address
      (let ((drop (list-drop-address list-id)))
        (when drop
          (let* ((at     (position #\@ drop))
                 (local  (subseq drop 0 at))
                 (domain (subseq drop at)))
            (concatenate 'string local "-request" domain))))))

(defun list-announce-p (list-id)
  "Return T if LIST-ID is an announce (owner-post-only) subgroup."
  (eq (list-subgroup list-id) :announce))

(defun list-owner-subgroup-p (list-id)
  "Return T if LIST-ID is the :owner routing subgroup."
  (eq (list-subgroup list-id) :owner))

(defun list-security-p (list-id)
  "Return T if LIST-ID is the :security embargoed/GPG subgroup."
  (eq (list-subgroup list-id) :security))

(defun list-commits-p (list-id)
  "Return T if LIST-ID is the :commits bot-post-only subgroup."
  (eq (list-subgroup list-id) :commits))

(defun list-bot-address (list-id)
  "Return the configured bot address for LIST-ID (:commits subgroup)."
  (getf (find-list list-id) :bot-address))

(defun list-owner-addresses (list-id)
  "Return list of owner addresses for LIST-ID."
  (let ((oa (getf (find-list list-id) :owner-addresses)))
    (cond
      ((null oa) (let ((single (list-owner-address list-id)))
                   (when single (list single))))
      ((listp oa) oa)
      (t (list oa)))))

(defun list-embargoed-until (list-id)
  "Return the embargo release datetime string for LIST-ID, or nil."
  (getf (find-list list-id) :embargoed-until))

(defun embargoed-p (list-id)
  "Return T if LIST-ID is currently under embargo (past release date)."
  (let ((until (list-embargoed-until list-id)))
    (when (and until (stringp until) (> (length until) 0))
      ;; Parse ISO8601 and compare — simple string comparison works for
      ;; well-formed YYYY-MM-DDTHH:MM:SS vs current time
      (string> until (iso8601-now)))))

(defun list-owner-address (list-id)
  "Return the configured owner address for LIST-ID, or nil."
  (getf (find-list list-id) :owner-address))

(defun owner-post-p (list-id from-addr)
  "Return T if FROM-ADDR is the configured owner for LIST-ID."
  (let ((owner (list-owner-address list-id)))
    (and owner
         (string-equal (string-downcase (or (extract-address from-addr) from-addr))
                       (string-downcase owner)))))

(defun list-auto-subscribe-p (list-id)
  "Return T if the list has :auto-subscribe set to T."
  (getf (find-list list-id) :auto-subscribe))


;;; ─────────────────────────────────────────────────────────────────────────────
;;; Per-sender rate limiting (#54)
;;; ─────────────────────────────────────────────────────────────────────────────

(defun ratelimit-path (list-id)
  (merge-pathnames (format nil "state/ratelimit/~A.sexp" list-id) (mlisp-home)))

(defun load-ratelimit (list-id)
  (let ((path (ratelimit-path list-id)))
    (if (probe-file path)
        (with-open-file (s path) (or (ignore-errors (read s)) '()))
        '())))

(defun save-ratelimit (list-id entries)
  (let* ((path (ratelimit-path list-id))
         (tmp  (format nil "~A.tmp" path)))
    (ensure-directories-exist path)
    (with-open-file (s tmp :direction :output :if-exists :supersede
                           :if-does-not-exist :create)
      (let ((*print-pretty* t) (*print-case* :downcase))
        (write entries :stream s) (terpri s)))
    (rename-file tmp path)))

(defun rate-limit-exceeded-p (list-id from-addr)
  "Return T if FROM-ADDR has exceeded :max-posts-per-day on LIST-ID.
   Updates the rolling window cache as a side effect."
  (let* ((max-posts (or (getf (find-list list-id) :max-posts-per-day) 0)))
    (when (> max-posts 0)
      (let* ((now     (get-universal-time))
             (window  86400)  ; 24 hours
             (entries (load-ratelimit list-id))
             (addr-lc (string-downcase from-addr))
             ;; Prune entries older than window
             (fresh   (remove-if (lambda (e)
                                   (> (- now (getf e :ts 0)) window))
                                 entries))
             ;; Count posts from this sender in window
             (sender-posts (count addr-lc fresh
                                  :key (lambda (e) (string-downcase (getf e :addr "")))
                                  :test #'string=)))
        (save-ratelimit list-id
                        (cons (list :addr from-addr :ts now) fresh))
        (>= sender-posts max-posts)))))

(defun subscriber-nomail-p (list-id address)
  "Return T if ADDRESS has :nomail t on LIST-ID."
  (let ((sub (find-subscriber list-id address)))
    (and sub (getf sub :nomail))))

(defun set-subscriber-nomail (list-id address flag)
  "Set :nomail FLAG on subscriber ADDRESS in LIST-ID."
  (let* ((lst (find-list list-id))
         (subs (getf lst :subscribers))
         (sub (find-if (lambda (s)
                         (string-equal (string-downcase (or (getf s :address) ""))
                                       (string-downcase address)))
                       subs)))
    (when sub
      (if (member :nomail sub)
          (setf (getf sub :nomail) flag)
          (nconc sub (list :nomail flag)))
      (save-state)
      t)))

(defun find-subscriber (list-id address)
  "Return the subscriber plist for ADDRESS in LIST-ID, or nil."
  (let ((lst (find-list list-id)))
    (find-if (lambda (s)
               (string-equal (string-downcase (or (getf s :address) ""))
                              (string-downcase address)))
             (getf lst :subscribers))))

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

(defun increment-bounce (list-id address &key (hard t))
  "Increment bounce count for ADDRESS on LIST-ID.
   :hard nil = soft bounce (4xx) — increments :soft-bounce-count, not toward removal.
   :hard t (default) = hard bounce (5xx) — time-windowed count.
   Returns new hard bounce count."
  (let* ((lst    (find-list list-id))
         (window (* (or (getf lst :bounce-window-days) 30) 86400))
         (now    (get-universal-time))
         (subs   (getf lst :subscribers))
         (rec    (find (string-downcase address) subs
                       :key (lambda (r) (string-downcase (or (getf r :address) "")))
                       :test #'string=)))
    (when rec
      (if (not hard)
          ;; Soft bounce: only count soft bounces
          (progn
            (setf (getf rec :soft-bounce-count)
                  (1+ (or (getf rec :soft-bounce-count) 0)))
            (or (getf rec :bounce-count) 0))
          ;; Hard bounce: time-windowed reset
          (let* ((last-at  (or (getf rec :last-bounce-at) 0))
                 (gap      (- now last-at))
                 (cur-cnt  (if (and (> window 0) (> gap window))
                               0  ; outside window: reset to 0 before incrementing
                               (or (getf rec :bounce-count) 0)))
                 (new-cnt  (1+ cur-cnt)))
            (setf (getf rec :bounce-count)    new-cnt)
            (setf (getf rec :last-bounce-at)  now)
            (setf (getf rec :last-bounce)     (iso8601-now))
            new-cnt)))))

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

;;; ─────────────────────────────────────────────────────────────────────────────
;;; File distribution archive helpers (#65)
;;; ─────────────────────────────────────────────────────────────────────────────

(defun distrib-archive-path (list-id)
  "Return path to distribution file archive directory for LIST-ID."
  (merge-pathnames (format nil "state/distrib/~A/" list-id) (mlisp-home)))

(defun add-file-to-distrib (list-id source-path description)
  "Copy SOURCE-PATH into the distrib archive for LIST-ID. Returns destination path."
  (let* ((dir   (distrib-archive-path list-id))
         (fname (file-namestring source-path))
         (dest  (merge-pathnames fname dir)))
    (ensure-directories-exist dest)
    (with-open-file (in source-path :element-type '(unsigned-byte 8))
      (with-open-file (out dest :direction :output :element-type '(unsigned-byte 8)
                                :if-exists :supersede :if-does-not-exist :create)
        (let ((buf (make-array 65536 :element-type '(unsigned-byte 8))))
          (loop for n = (read-sequence buf in) while (> n 0)
                do (write-sequence buf out :end n)))))
    (let* ((lst   (find-list list-id))
           (files (or (getf lst :distrib-files) '()))
           (size  (with-open-file (f dest) (file-length f)))
           (entry (list :name fname :path (namestring dest)
                        :size size :date (iso8601-now)
                        :description (or description ""))))
      (if (member :distrib-files lst)
          (setf (getf lst :distrib-files)
                (cons entry (remove-if (lambda (e) (equal (getf e :name) fname))
                                       files)))
          (nconc lst (list :distrib-files (list entry))))
      (save-state))
    dest))
(defun list-distrib-files (list-id)
  "Return formatted file listing (AllFix FILES.BBS style)."
  (let* ((dir   (distrib-archive-path list-id))
         (files (when (probe-file dir)
                  (directory (merge-pathnames "*" dir)))))
    (if files
        (with-output-to-string (s)
          (format s "Files available from ~A:~%~%" list-id)
          (format s "~-30A ~8A  ~10A  ~A~%" "Filename" "Size" "Date" "Description")
          (format s "~30,,,'-<~>  ~8,,,'-<~>  ~10,,,'-<~>  ~A~%" "" "" "" "")
          (dolist (f files)
            (let* ((name (file-namestring f))
                   (size (ignore-errors (with-open-file (s f) (file-length s))))
                   (size-str (if size (format nil "~AK" (ceiling size 1024)) "?")))
              (format s "~-30A ~8A~%" name size-str)))
          (format s "~%To retrieve a file: send 'get ~A <filename>' to ~A~%"
                  list-id (list-request-address list-id)))
        (format nil "No files available from ~A.~%" list-id))))
