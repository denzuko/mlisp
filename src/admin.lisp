;;;; src/admin.lisp — mlisp-admin: management CLI for mlisp config and state
;;;;
;;;; Subcommands:
;;;;   show-config                       print resolved paths
;;;;   init [--dir <path>]               scaffold new config dir
;;;;   list-lists                        print all lists
;;;;   add-list <id> <drop> <desc>       add a list
;;;;   rm-list  <id>                     remove a list
;;;;   list-subs <list-id>               print subscribers
;;;;   add-sub  <list-id> <address>      add subscriber (consent: admin-add)
;;;;   rm-sub   <list-id> <address>      remove subscriber (GDPR erasure)

(defpackage #:mlisp-admin
  (:use #:cl #:mlisp)
  (:export #:admin-main))

(in-package #:mlisp-admin)

;;; Forward special declarations
(declaim (special mlisp:*state* mlisp:*mlisp-home-override*))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Seed data for init subcommand
;;; ─────────────────────────────────────────────────────────────────────────────

(defparameter *seed-state*
  '(:lists
    ((:id "mlisp-discuss"
      :subgroup :discuss
      :drop-address "mlisp-discuss@example.com"
      :request-address "mlisp-request@example.com"
      :description "General discussion (subscriber-writable)"
      :postal-address "Your Organization, 123 Main St, City ST 00000, USA"
      :privacy-url "https://example.com/privacy"
      :auto-subscribe nil :confirm-subscribe nil :max-bounces 5 :subscribers ())
     (:id "mlisp-announce"
      :subgroup :announce
      :drop-address "mlisp-announce@example.com"
      :request-address "mlisp-request@example.com"
      :description "Announcements (owner-post-only)"
      :postal-address "Your Organization, 123 Main St, City ST 00000, USA"
      :privacy-url "https://example.com/privacy"
      :auto-subscribe nil :confirm-subscribe nil :max-bounces 5 :subscribers ())
     (:id "mlisp-devel"
      :subgroup :devel
      :drop-address "mlisp-devel@example.com"
      :request-address "mlisp-request@example.com"
      :description "Patches and VCS traffic"
      :postal-address "Your Organization, 123 Main St, City ST 00000, USA"
      :privacy-url "https://example.com/privacy"
      :auto-subscribe nil :confirm-subscribe nil :max-bounces 5 :subscribers ())
     (:id "mlisp-distrib"
      :subgroup :distrib
      :drop-address "mlisp-distrib@example.com"
      :request-address "mlisp-request@example.com"
      :description "Binary/file attachment releases"
      :postal-address "Your Organization, 123 Main St, City ST 00000, USA"
      :privacy-url "https://example.com/privacy"
      :auto-subscribe nil :confirm-subscribe nil :max-bounces 5 :subscribers ())
     (:id "mlisp-request"
      :subgroup :request
      :drop-address "mlisp-request@example.com"
      :request-address "mlisp-request@example.com"
      :description "Admin commands (subscribe/unsubscribe/help)"
      :postal-address "Your Organization, 123 Main St, City ST 00000, USA"
      :privacy-url "https://example.com/privacy"
      :auto-subscribe nil :confirm-subscribe nil :max-bounces 5 :subscribers ())))
  "Seed state written by `init` subcommand.")

(defun seed-footer-template (list-id drop postal)
  (format nil
"(:document
 (:raw \".sp\")
 (:raw \".ll 72\")
 (:raw \".nf\")
 (:raw \"------------------------------------------------------------------------\")
 (:p \"You are receiving this because you subscribed to the ~A list.\")
 (:raw \".sp\")
 (:p \"To unsubscribe, send email to ~A\")
 (:p \"with subject: unsubscribe\")
 (:raw \".sp\")
 (:p \"~A\")
 (:raw \".fi\"))
"
          list-id drop postal))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: show-config
;;; ─────────────────────────────────────────────────────────────────────────────

;;; ─── parse-flags: two-phase flag extraction ──────────────────────────────────
;;; Strips known "--flag value" pairs out of a raw arg list, returning the
;;; remaining positional args plus a plist of extracted flag values. This
;;; replaces the repeated (position "--foo" args :test #'string=) / (nth (1+ p) ...)
;;; idiom that appears in install-procmail, export-ldif, export-csv,
;;; bugs-add-package, bugs-list, bugs-report, add-namespace, etc.

(defun parse-flags (args flag-names)
  "Extract flag values from ARGS per FLAG-NAMES. Each entry in FLAG-NAMES is
   either:
     - a string \"--foo\"            (value flag: consumes the following arg)
     - a list (\"--foo\" :boolean)   (presence flag: sets to T, consumes nothing)
   Returns (values positional-args flags-plist) where flags-plist maps
   :foo -> value (value flags) or :foo -> t (boolean flags present),
   absent if not given."
  (let ((positional '())
        (flags '())
        (tail args))
    (flet ((flag-string (f) (if (consp f) (first f) f))
           (boolean-p   (f) (and (consp f) (eq (second f) :boolean))))
      (loop while tail do
        (let* ((a    (car tail))
               (spec (find a flag-names :key #'flag-string :test #'string=)))
          (cond
            ((null spec)
             (push a positional) (setf tail (cdr tail)))
            ((boolean-p spec)
             (setf (getf flags (intern (string-upcase (subseq a 2)) :keyword)) t)
             (setf tail (cdr tail)))
            (t
             (setf (getf flags (intern (string-upcase (subseq a 2)) :keyword))
                   (second tail))
             (setf tail (cddr tail)))))))
    (values (nreverse positional) flags)))

;;; ─── define-admin-cmd+: canonical cmd-* definition macro ─────────────────────
;;; This is the SINGLE implementation of the arg-guard + flag-parsing
;;; boilerplate shared by every cmd-* command. define-admin-cmd and
;;; define-admin-cmd* (below) are thin forwarding aliases that expand
;;; through this -- there is exactly one place that builds the
;;; destructuring-bind lambda-list and the unless+return-from guard,
;;; so a future fix applies everywhere automatically.
;;;
;;; ARG-SPEC is a full lambda-list: (id drop) or (id drop &optional desc)
;;; or (id &rest members). Only symbols before &optional/&rest are guarded.
;;; FLAG-NAMES is a list of "--flag" strings; each becomes a body-visible
;;; variable (e.g. "--reason" -> REASON), bound to its value or nil via
;;; parse-flags. Pass () for FLAG-NAMES when there are no flags.
;;;
;;;   (define-admin-cmd+ lock (list-id) ("--reason") "<list-id>" body...)

(defmacro define-admin-cmd+ (name arg-spec flag-names usage &body body)
  "Canonical cmd-NAME definition: parse-flags + positional/optional/rest
   destructuring-bind + unless+return-from guard on required args."
  (let* ((fn-name   (intern (format nil "CMD-~A" (string-upcase name)) *package*))
         (args-sym  (gensym "ARGS"))
         (flags-sym (gensym "FLAGS"))
         (opt-pos   (position '&optional arg-spec))
         (rest-pos  (position '&rest arg-spec))
         (split     (or opt-pos rest-pos (length arg-spec)))
         (required  (subseq arg-spec 0 split))
         (opt-args  (if opt-pos
                        (subseq arg-spec (1+ opt-pos) (or rest-pos (length arg-spec)))
                        '()))
         (rest-arg  (when rest-pos (nth (1+ rest-pos) arg-spec)))
         (lambda-list `(&optional ,@required ,@opt-args
                        ,@(if rest-arg `(&rest ,rest-arg) '(&rest _))))
         (flag-strings (mapcar (lambda (f) (if (consp f) (first f) f)) flag-names))
         (flag-vars (mapcar (lambda (f) (intern (string-upcase (subseq f 2)) *package*))
                             flag-strings)))
    `(defun ,fn-name (,args-sym)
       (multiple-value-bind (,args-sym ,flags-sym) (parse-flags ,args-sym ',flag-names)
         (let ,(mapcar (lambda (var flag)
                          `(,var (getf ,flags-sym
                                       ,(intern (string-upcase (subseq flag 2)) :keyword))))
                        flag-vars flag-strings)
           (declare (ignorable ,@flag-vars))
           (destructuring-bind ,lambda-list ,args-sym
             ,@(unless rest-arg '((declare (ignore _))))
             ,@(when required
                 `((unless ,(if (= 1 (length required))
                                (first required)
                                `(and ,@required))
                     (format *error-output* "mlisp-admin: ~A requires ~A~%"
                             ,(string-downcase (string name)) ,usage)
                     (return-from ,fn-name 1))))
             ,@body))))))

;;; ─── define-admin-cmd / define-admin-cmd*: thin forwarding aliases ───────────
;;; Both expand to define-admin-cmd+ with an empty FLAG-NAMES list. No
;;; existing call sites change: define-admin-cmd's REQUIRED-ARGS is a flat
;;; list with no &optional/&rest, which is valid ARG-SPEC as-is;
;;; define-admin-cmd*'s ARG-SPEC is already the same shape define-admin-cmd+
;;; expects.

(defmacro define-admin-cmd (name required-args usage &body body)
  "Alias: (define-admin-cmd NAME (req...) usage body...)
   = (define-admin-cmd+ NAME (req...) () usage body...)"
  `(define-admin-cmd+ ,name ,required-args () ,usage ,@body))

(defmacro define-admin-cmd* (name arg-spec usage &body body)
  "Alias: (define-admin-cmd* NAME arg-spec usage body...)
   = (define-admin-cmd+ NAME arg-spec () usage body...)"
  `(define-admin-cmd+ ,name ,arg-spec () ,usage ,@body))

(defun cmd-show-config ()
  (format t "config-dir:    ~A~%" (mlisp:mlisp-home))
  (format t "state.sexp:    ~A~%" (mlisp:state-path))
  (format t "audit.sexp:    ~A~%" (mlisp:audit-path))
  (format t "templates-dir: ~A~%" (mlisp:template-dir))
  (format t "sendmail:      ~A~%" (mlisp:sendmail-path))
  0)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: init
;;; ─────────────────────────────────────────────────────────────────────────────

(defun cmd-init (args)
  "Scaffold a new config directory with seed state and templates."
  (let* ((dir-raw (if (and (first args) (string= (first args) "--dir"))
                      (second args)
                      (mlisp:mlisp-home)))
         ;; Ensure trailing slash so merge-pathnames treats as directory
         (dir (uiop:ensure-directory-pathname dir-raw))
         (state-dir  (merge-pathnames "state/"     dir))
         (tmpl-dir   (merge-pathnames "templates/" dir))
         (state-file (merge-pathnames "state.sexp" state-dir)))

    (ensure-directories-exist state-dir)
    (ensure-directories-exist tmpl-dir)

    ;; Write seed state only if not already present
    (unless (probe-file state-file)
      (with-open-file (s state-file :direction :output :if-does-not-exist :create)
        (let ((*print-pretty* t) (*print-case* :downcase)
              (*print-readably* nil) (*print-escape* t))
          (write *seed-state* :stream s)
          (terpri s)))
      (format t "Created ~A~%" state-file))

    ;; Write seed templates for default lists
    (dolist (entry (getf *seed-state* :lists))
      (let* ((id   (getf entry :id))
             (drop (getf entry :drop-address))
             (addr (getf entry :postal-address)))
        (dolist (tpl '("welcome" "help" "goodbye" "footer"))
          (let ((path (merge-pathnames
                       (format nil "~A.~A.sexp" id tpl) tmpl-dir)))
            (unless (probe-file path)
              (with-open-file (s path :direction :output :if-does-not-exist :create)
                (if (string= tpl "footer")
                    (write-string (seed-footer-template id drop addr) s)
                    (format s "(:document (:title \"~A — ~:(~A~)\") (:pp \"Automated message.\") (:raw \".br\"))~%"
                            (string-upcase id) tpl)))
              (format t "Created ~A~%" path))))))

    (format t "Config dir ready: ~A~%" dir)
    0))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: list-lists
;;; ─────────────────────────────────────────────────────────────────────────────

(defun cmd-list-lists ()
  (mlisp:load-state)
  (let ((lists (getf mlisp:*state* :lists)))
    (if (null lists)
        (format t "No lists configured.~%")
        (dolist (lst lists)
          (format t "~A~%  drop:  ~A~%  desc:  ~A~%  subs:  ~A~%"
                  (getf lst :id)
                  (getf lst :drop-address)
                  (or (getf lst :description) "(none)")
                  (length (getf lst :subscribers))))))
  0)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: list-subs
;;; ─────────────────────────────────────────────────────────────────────────────

(define-admin-cmd list-subs (list-id) "<list-id>"
  (mlisp:load-state)
  (let ((lst (mlisp:find-list list-id)))
    (unless lst
      (format *error-output* "mlisp-admin: unknown list ~A~%" list-id)
      (return-from cmd-list-subs 1))
    (let ((subs (mlisp:list-subscribers list-id)))
      (if (null subs)
          (format t "No subscribers on ~A.~%" list-id)
          (dolist (rec subs)
            (format t "~A~:[~; [NOMAIL]~]~%  subscribed-at: ~A~%  consent-method: ~A~%"
                    (or (getf rec :address) (format nil "hash:~A" (getf rec :address-hash)))
                    (getf rec :nomail)
                    (getf rec :subscribed-at)
                    (getf rec :consent-method)))))
    0))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: add-sub
;;; ─────────────────────────────────────────────────────────────────────────────

(define-admin-cmd add-sub (list-id address) "<list-id> <address>"
  (mlisp:load-state)
  (unless (mlisp:find-list list-id)
    (format *error-output* "mlisp-admin: unknown list ~A~%" list-id)
    (return-from cmd-add-sub 1))
  ;; Use admin-add consent method instead of email-subscribe-command
  (unless (mlisp:subscriber-p list-id address)
    (let ((lst (mlisp:find-list list-id)))
      (setf (getf lst :subscribers)
            (cons (list :address (string-downcase address)
                        :subscribed-at (mlisp:iso8601-now)
                        :consent-method "admin-add")
                  (getf lst :subscribers)))))
  (mlisp:save-state)
  (mlisp:audit-append (list :event :subscribe :list list-id
                             :address address :via "mlisp-admin"))
  (format t "Added ~A to ~A~%" address list-id)
  0)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: rm-sub
;;; ─────────────────────────────────────────────────────────────────────────────

(define-admin-cmd rm-sub (list-id address) "<list-id> <address>"
  (mlisp:load-state)
  (unless (mlisp:find-list list-id)
    (format *error-output* "mlisp-admin: unknown list ~A~%" list-id)
    (return-from cmd-rm-sub 1))
  ;; GDPR Art.17 erasure
  (mlisp:remove-subscriber list-id address)
  (mlisp:save-state)
  (mlisp:audit-append (list :event :unsubscribe :list list-id
                             :address address :via "mlisp-admin"))
  (format t "Removed ~A from ~A~%" address list-id)
  0)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: add-list
;;; ─────────────────────────────────────────────────────────────────────────────

(define-admin-cmd* add-list (id drop &optional desc) "<id> <drop-address> [<description>]"
  (mlisp:load-state)
  (when (mlisp:find-list id)
    (format *error-output* "mlisp-admin: list ~A already exists~%" id)
    (return-from cmd-add-list 1))
  (setf (getf mlisp:*state* :lists)
        (append (getf mlisp:*state* :lists)
                (list (list :id id
                            :drop-address drop
                            :request-address (mlisp:list-request-address id)
                            :description (or desc "")
                            :postal-address
                            (mlisp:list-postal-address "discuss")
                            :privacy-url
                            (mlisp:list-privacy-url "discuss")
                            :auto-subscribe nil
                            :max-bounces 5
                            :subscribers '()))))
  (mlisp:save-state)
  (format t "Created list ~A -> ~A~%" id drop)
  0)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: rm-list
;;; ─────────────────────────────────────────────────────────────────────────────

(define-admin-cmd rm-list (id) "<id>"
  (mlisp:load-state)
  (unless (mlisp:find-list id)
    (format *error-output* "mlisp-admin: unknown list ~A~%" id)
    (return-from cmd-rm-list 1))
  (setf (getf mlisp:*state* :lists)
        (remove id (getf mlisp:*state* :lists)
                :key (lambda (l) (getf l :id))
                :test #'string=))
  (mlisp:save-state)
  (format t "Removed list ~A~%" id)
  0)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Admin entry point
;;; ─────────────────────────────────────────────────────────────────────────────


;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: install-procmail
;;; ─────────────────────────────────────────────────────────────────────────────

(defun procmail-recipe (list-id drop-address mlisp-bin home-dir)
  "Return a procmail recipe string for LIST-ID.
   Includes FROM_DAEMON guard, Precedence guard, idempotency marker.
   For :request subgroup: command-only recipe (no -request sibling).
   For other subgroups: list recipe + -request sibling recipe."
  (let* ((sg       (mlisp:list-subgroup list-id))
         (is-req   (eq sg :request))
         (at-pos   (position #\@ drop-address))
         (local    (if at-pos (subseq drop-address 0 at-pos) drop-address))
         (domain   (if at-pos (subseq drop-address at-pos) ""))
         (req-drop (concatenate 'string local "-request" domain))
         ;; For --mode request: use the -request sibling address for matching
         ;; For :request lists: use --mode request directly
         (mode-arg (if is-req "--mode request " "")))
    (if is-req
        ;; :request subgroup: single recipe, command-only
        (format nil
"# mlisp: ~A
:0
* !^FROM_DAEMON
* !^FROM_MAILER
* !^Precedence: (bulk|junk|list)
* ^^TO_~A
| ~A --home ~A --mode request ~A
"
                list-id drop-address mlisp-bin home-dir list-id)
        ;; Other subgroups: list recipe + -request sibling
        (format nil
"# mlisp: ~A
:0
* !^FROM_DAEMON
* !^FROM_MAILER
* !^Precedence: (bulk|junk|list)
* ^^TO_~A
| ~A --home ~A ~A~A

# mlisp: ~A-request
:0
* ^^TO_~A
| ~A --home ~A --mode request ~A
"
                list-id drop-address mlisp-bin home-dir mode-arg list-id
                list-id req-drop mlisp-bin home-dir list-id))))

(defun procmailrc-has-list-p (path list-id)
  "Return T if PATH already contains a mlisp recipe for LIST-ID."
  (when (probe-file path)
    (with-open-file (s path :direction :input)
      (let ((marker (format nil "# mlisp: ~A" list-id)))
        (loop for line = (read-line s nil nil)
              while line
              when (string= line marker)
              return t)))))

(defun cmd-install-procmail (args)
  "Append procmail recipes for configured lists to ~~/.procmailrc.
   Args: [--dry-run] [--list <id>] [--help]"
  (let ((dry-run nil)
        (filter-list nil)
        (tail args))

    ;; Parse subcommand flags
    (loop while tail do
      (let ((a (car tail)))
        (cond
          ((or (string= a "--help") (string= a "-h"))
           (format t
"Usage: mlisp-admin install-procmail [--list <id>] [--dry-run]

  --list <id>    install recipe for one list only
  --dry-run      print what would be written; do not modify ~~/.procmailrc
  --help         show this help
")
           (return-from cmd-install-procmail 0))
          ((string= a "--dry-run")
           (setf dry-run t)
           (setf tail (cdr tail)))
          ((string= a "--list")
           (if (cdr tail)
               (progn (setf filter-list (string-downcase (cadr tail)))
                      (setf tail (cddr tail)))
               (progn (format *error-output*
                              "mlisp-admin: --list requires an argument~%")
                      (return-from cmd-install-procmail 1))))
          (t (setf tail (cdr tail))))))

    (mlisp:load-state)

    ;; Validate --list target if given
    (when (and filter-list (null (mlisp:find-list filter-list)))
      (format *error-output* "mlisp-admin: unknown list ~A~%" filter-list)
      (return-from cmd-install-procmail 1))

    ;; Determine paths
    (let* ((home-dir   (mlisp:mlisp-home))
           (mlisp-bin  (or (uiop:getenv "MLISP_BIN")
                           (namestring
                            (truename sb-ext:*runtime-pathname*))
                           "/usr/local/bin/mlisp"))
           ;; Replace mlisp-admin path with mlisp path
           (mlisp-bin  (let ((b (pathname mlisp-bin)))
                         (namestring
                          (make-pathname
                           :directory (pathname-directory b)
                           :name "mlisp"
                           :type (pathname-type b)))))
           (procmailrc (merge-pathnames ".procmailrc"
                                        (uiop:ensure-directory-pathname
                                         (sb-ext:posix-getenv "HOME"))))
           (lists      (if filter-list
                           (list (mlisp:find-list filter-list))
                           (getf mlisp:*state* :lists))))

      (if dry-run
          (progn
            (format t "# Would append to ~A:~%~%" procmailrc)
            (dolist (lst lists)
              (let* ((id   (getf lst :id))
                     (drop (getf lst :drop-address)))
                (if (procmailrc-has-list-p procmailrc id)
                    (format t "# SKIP (already present): ~A~%~%" id)
                    (format t "~A" (procmail-recipe id drop mlisp-bin
                                                    home-dir))))))
          (progn
            (dolist (lst lists)
              (let* ((id   (getf lst :id))
                     (drop (getf lst :drop-address)))
                (if (procmailrc-has-list-p procmailrc id)
                    (format t "Skipped ~A (already in ~A)~%" id procmailrc)
                    (progn
                      (with-open-file (s procmailrc
                                         :direction :output
                                         :if-exists :append
                                         :if-does-not-exist :create)
                        (write-string
                         (procmail-recipe id drop mlisp-bin home-dir) s))
                      (format t "Added ~A -> ~A~%" id procmailrc))))))))
    0))


;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: set-option
;;; ─────────────────────────────────────────────────────────────────────────────


;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: add-namespace
;;; ─────────────────────────────────────────────────────────────────────────────

(defparameter *default-subgroups*
  '((:discuss  "subscriber-writable general discussion")
    (:announce "owner-post-only notifications")
    (:devel    "patches and VCS traffic")
    (:distrib  "binary/file attachment releases")
    (:request  "admin commands (subscribe/unsubscribe/help)")
    (:owner    "owner/admin contact (not subscriber-visible)")
    (:security "security disclosures (GPG-required, embargo-capable)")
    (:commits  "automated VCS/CI notifications (bot-post-only)")
    (:users    "end-user support and general questions"))
  "Default subgroups created by add-namespace.")

(defun cmd-add-namespace (args)
  "Create all subgroup list records for a namespace.
   Usage: add-namespace <name> <base-address> [--subgroups sg1,sg2,...]
   Example: add-namespace mlisp mlisp@panix.com
   Creates: mlisp-discuss, mlisp-announce, mlisp-devel, mlisp-distrib, mlisp-request"
  (let ((name     (first args))
        (base     (second args))
        (rest-args (cddr args)))
    (unless (and name base)
      (format *error-output*
              "mlisp-admin: add-namespace requires <name> <base-address>~%")
      (return-from cmd-add-namespace 1))
    (mlisp:load-state)
    ;; Parse --subgroups flag
    (let* ((sg-filter
            (let ((pos (position "--subgroups" rest-args :test #'string=)))
              (when (and pos (nth (1+ pos) rest-args))
                (let* ((raw    (nth (1+ pos) rest-args))
                       (result (list))
                       (cur    ""))
                  (dolist (c (coerce raw (quote list)))
                    (if (char= c #\,)
                        (let ((s (string-trim " " cur)))
                          (when (> (length s) 0)
                            (push (intern (string-upcase s) :keyword) result))
                          (setf cur ""))
                        (setf cur (concatenate (quote string) cur (string c)))))
                  (let ((s (string-trim " " cur)))
                    (when (> (length s) 0)
                      (push (intern (string-upcase s) :keyword) result)))
                  (nreverse result)))))
           (subgroups (if sg-filter
                          (remove-if-not
                           (lambda (entry)
                             (member (first entry) sg-filter))
                           *default-subgroups*)
                          *default-subgroups*))
           ;; Derive request address from base: foo@host → foo-request@host
           (at-pos  (position #\@ base))
           (local   (if at-pos (subseq base 0 at-pos) base))
           (domain  (if at-pos (subseq base at-pos) ""))
           (req-addr (concatenate 'string local "-request" domain)))
      (dolist (sg-entry subgroups)
        (let* ((sg      (first sg-entry))
               (sg-name (string-downcase (symbol-name sg)))
               (id      (format nil "~A-~A" name sg-name))
               (drop    (concatenate 'string local "-" sg-name domain)))
          ;; Skip if already exists
          (unless (mlisp:find-list id)
            (let ((new-list
                   (list :id id
                         :subgroup sg
                         :drop-address drop
                         :request-address req-addr
                         :description (format nil "~A ~A" name (second sg-entry))
                         :postal-address
                         (or (mlisp:list-postal-address "mlisp-discuss")
                             (mlisp:list-postal-address (caar (getf mlisp:*state* :lists)))
                             "")
                         :privacy-url
                         (or (mlisp:list-privacy-url "mlisp-discuss")
                             (mlisp:list-privacy-url (caar (getf mlisp:*state* :lists)))
                             "")
                         :auto-subscribe nil
                         :max-bounces 5
                         :subscribers '())))
              (setf (getf mlisp:*state* :lists)
                    (append (getf mlisp:*state* :lists) (list new-list)))
              (format t "Created ~A -> ~A~%" id drop)))))
      (mlisp:save-state)
      0)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: list-namespace
;;; ─────────────────────────────────────────────────────────────────────────────

(define-admin-cmd list-namespace (ns) "<name>"
  "Show all subgroups for a namespace prefix.
   Usage: list-namespace <name>"
  (mlisp:load-state)
  (let ((siblings (remove-if-not
                   (lambda (lst)
                     (let ((ns2 (mlisp:list-namespace (getf lst :id))))
                       (and ns2 (string= ns2 (string-downcase ns)))))
                   (getf mlisp:*state* :lists))))
    (if (null siblings)
        (progn
          (format *error-output* "mlisp-admin: no lists found for namespace ~A~%" ns)
          (return-from cmd-list-namespace 1))
        (dolist (lst siblings)
          (format t "~A~%  subgroup:  :~A~%  drop:      ~A~%  request:   ~A~%  subs:      ~A~%"
                  (getf lst :id)
                  (string-downcase (symbol-name (or (getf lst :subgroup) :unknown)))
                  (getf lst :drop-address)
                  (getf lst :request-address)
                  (length (getf lst :subscribers)))))
    0))


;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: set-nomail
;;; ─────────────────────────────────────────────────────────────────────────────


;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: add-sub-batch / rm-sub-batch
;;; ─────────────────────────────────────────────────────────────────────────────

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: diagnose
;;; ─────────────────────────────────────────────────────────────────────────────

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: show-pending / clear-pending
;;; ─────────────────────────────────────────────────────────────────────────────

(define-admin-cmd set-nomail (list-id address flag-str) "<list-id> <address> true|false"
  (mlisp:load-state)
  (let ((flag (cond ((string-equal flag-str "true")  t)
                    ((string-equal flag-str "false") nil)
                    (t (format *error-output* "mlisp-admin: flag must be true or false~%")
                       (return-from cmd-set-nomail 1)))))
    (if (mlisp:set-subscriber-nomail list-id address flag)
        (progn
          (format t "Set ~A NOMAIL=~A on ~A~%" address flag list-id)
          0)
        (progn
          (format *error-output* "mlisp-admin: ~A not found in ~A~%" address list-id)
          1))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: lock / unlock
;;; ─────────────────────────────────────────────────────────────────────────────

(define-admin-cmd+ lock (list-id) ("--reason") "<list-id>"
  (mlisp:load-state)
  (let ((lst (mlisp:find-list list-id)))
    (unless lst
      (format *error-output* "mlisp-admin: unknown list ~A~%" list-id)
      (return-from cmd-lock 1))
    (if (member :locked lst)
        (setf (getf lst :locked) t)
        (nconc lst (list :locked t)))
    (when reason
      (if (member :lock-reason lst)
          (setf (getf lst :lock-reason) reason)
          (nconc lst (list :lock-reason reason))))
    (mlisp:save-state)
    (format t "Locked ~A~@[ — ~A~]~%" list-id reason)
    0))

(define-admin-cmd unlock (list-id) "<list-id>"
  (mlisp:load-state)
  (let ((lst (mlisp:find-list list-id)))
    (unless lst
      (format *error-output* "mlisp-admin: unknown list ~A~%" list-id)
      (return-from cmd-unlock 1))
    ;; Remove :locked and :lock-reason from plist
    (let ((new-plist
           (loop for (k v) on lst by #'cddr
                 unless (member k '(:locked :lock-reason))
                 nconc (list k v))))
      ;; Replace list contents
      (loop for (k v) on new-plist by #'cddr do
        (setf (getf lst k) v)))
    (remf lst :locked)
    (mlisp:save-state)
    (format t "Unlocked ~A~%" list-id)
    0))


;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: show-pending / clear-pending
;;; ─────────────────────────────────────────────────────────────────────────────

(define-admin-cmd show-pending (list-id) "<list-id>"
  (mlisp:load-state)
  (let ((entries (mlisp:pending-entries list-id)))
    (if (null entries)
        (format t "No pending confirmations for ~A~%" list-id)
        (dolist (e entries)
          (format t "~A  type=~A  pending since ~A~%"
                  (getf e :address)
                  (getf e :type)
                  (getf e :created-at))))
    0))

(define-admin-cmd clear-pending (list-id) "<list-id>"
  (mlisp:load-state)
  (let ((n (mlisp:clear-expired-pending list-id)))
    (format t "Cleared ~A expired token~:P from ~A~%" n list-id)
    0))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: add-sub-batch / rm-sub-batch
;;; ─────────────────────────────────────────────────────────────────────────────

(defun parse-address-line (line)
  "Parse a single address line. Supports:
   addr@example.com
   Name <addr@example.com>
   Returns the email address string or nil if blank/comment."
  (let ((trimmed (string-trim '(#\Space #\Tab #\Return #\Newline) line)))
    (cond
      ((= (length trimmed) 0) nil)          ; blank
      ((char= (char trimmed 0) #\#) nil)    ; comment
      (t
       (let ((lt (position #\< trimmed :from-end nil))
             (gt (position #\> trimmed :from-end t)))
         (if (and lt gt (< lt gt))
             ;; "Name <addr>" format
             (string-trim '(#\Space #\Tab)
                          (subseq trimmed (1+ lt) gt))
             ;; bare address
             trimmed))))))

(defun cmd-add-sub-batch (args)
  "add-sub-batch <list-id> [<file>]
   Reads addresses from file or stdin, one per line. Skips blanks and # comments.
   Supports 'Name <addr>' format. Idempotent."
  (let ((list-id (first args))
        (file    (second args)))
    (unless list-id
      (format *error-output* "mlisp-admin: add-sub-batch requires <list-id>~%")
      (return-from cmd-add-sub-batch 1))
    (mlisp:load-state)
    (unless (mlisp:find-list list-id)
      (format *error-output* "mlisp-admin: unknown list ~A~%" list-id)
      (return-from cmd-add-sub-batch 1))
    (let ((added 0) (skipped 0) (invalid 0)
          (stream (if (and file (probe-file file))
                      (open file :direction :input)
                      *standard-input*)))
      (unwind-protect
           (loop for line = (read-line stream nil nil)
                 while line do
                   (let ((addr (parse-address-line line)))
                     (cond
                       ((null addr) nil)  ; blank or comment
                       ((not (position #\@ addr))
                        (format *error-output* "  skipping invalid: ~A~%" addr)
                        (incf invalid))
                       ((mlisp:subscriber-p list-id addr)
                        (incf skipped))
                       (t
                        (mlisp:add-subscriber list-id addr)
                        (incf added)))))
        (when (and file (probe-file file))
          (close stream)))
      (mlisp:save-state)
      (mlisp:audit-append (list :event :batch-subscribe :list list-id
                                :added added :skipped skipped))
      (format t "~A: added ~A, skipped ~A (already subscribed), ~A invalid~%"
              list-id added skipped invalid)
      0)))

(defun cmd-rm-sub-batch (args)
  "rm-sub-batch <list-id> [<file>]
   Removes addresses from file or stdin."
  (let ((list-id (first args))
        (file    (second args)))
    (unless list-id
      (format *error-output* "mlisp-admin: rm-sub-batch requires <list-id>~%")
      (return-from cmd-rm-sub-batch 1))
    (mlisp:load-state)
    (unless (mlisp:find-list list-id)
      (format *error-output* "mlisp-admin: unknown list ~A~%" list-id)
      (return-from cmd-rm-sub-batch 1))
    (let ((removed 0) (not-found 0)
          (stream (if (and file (probe-file file))
                      (open file :direction :input)
                      *standard-input*)))
      (unwind-protect
           (loop for line = (read-line stream nil nil)
                 while line do
                   (let ((addr (parse-address-line line)))
                     (when addr
                       (if (mlisp:subscriber-p list-id addr)
                           (progn (mlisp:remove-subscriber list-id addr)
                                  (incf removed))
                           (incf not-found)))))
        (when (and file (probe-file file))
          (close stream)))
      (mlisp:save-state)
      (mlisp:audit-append (list :event :batch-unsubscribe :list list-id :removed removed))
      (format t "~A: removed ~A, ~A not found~%" list-id removed not-found)
      0)))


;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: export-ldif
;;; ─────────────────────────────────────────────────────────────────────────────

(defun cmd-export-ldif (args)
  "export-ldif <list-id> [--base-dn <dn>] [--output <file>]
   Export list subscribers as LDIF (RFC 2849) groupOfNames entry."
  (let ((list-id  (first args))
        (base-dn  (let ((p (position "--base-dn" args :test #'string=)))
                    (if p (nth (1+ p) args) "dc=example,dc=com")))
        (out-file (let ((p (position "--output" args :test #'string=)))
                    (when p (nth (1+ p) args)))))
    (unless list-id
      (format *error-output* "mlisp-admin: export-ldif requires <list-id>~%")
      (return-from cmd-export-ldif 1))
    (mlisp:load-state)
    (let* ((lst   (mlisp:find-list list-id))
           (subs  (mlisp:list-subscribers list-id))
           (desc  (or (getf lst :description) list-id))
           (hash? (getf lst :hash-contacts))
           (ldif
            (with-output-to-string (s)
              ;; Group entry
              (format s "dn: cn=~A,ou=mailinglists,~A~%" list-id base-dn)
              (format s "objectClass: top~%")
              (format s "objectClass: groupOfNames~%")
              (format s "cn: ~A~%" list-id)
              (format s "description: ~A~%" desc)
              (if subs
                  (dolist (sub subs)
                    (let ((uid (if hash?
                                   (getf sub :address-hash)
                                   (when (getf sub :address)
                                     (substitute #\. #\@
                                       (getf sub :address))))))
                      (when uid
                        (format s "member: uid=~A,ou=people,~A~%" uid base-dn))))
                  ;; LDIF groupOfNames requires at least one member
                  (format s "member: cn=empty,ou=mailinglists,~A~%" base-dn))
              (terpri s))))
      (if out-file
          (progn
            (with-open-file (f out-file :direction :output
                                        :if-exists :supersede
                                        :if-does-not-exist :create)
              (write-string ldif f))
            (format t "Exported ~A to ~A~%" list-id out-file))
          (write-string ldif *standard-output*))
      0)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: verp-decode
;;; ─────────────────────────────────────────────────────────────────────────────

(define-admin-cmd verp-decode (verp-addr) "<verp-address>"
  "verp-decode <verp-address>
   Decode a VERP-encoded bounce address to the original subscriber address."
  (let ((decoded (mlisp:verp-decode verp-addr)))
    (if decoded
        (progn (format t "~A~%" decoded) 0)
        (progn
          (format *error-output* "mlisp-admin: could not decode VERP address: ~A~%" verp-addr)
          1))))


;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: diagnose
;;; ─────────────────────────────────────────────────────────────────────────────

(define-admin-cmd diagnose (list-id) "<list-id>"
  "diagnose <list-id>
   Print a health report for the list to stdout."
  (mlisp:load-state)
  (let* ((lst      (mlisp:find-list list-id))
         (ns       (mlisp:list-namespace list-id))
         (siblings (when ns (mlisp:namespace-siblings list-id))))
    (unless lst
      (format *error-output* "mlisp-admin: unknown list ~A~%" list-id)
      (return-from cmd-diagnose 1))
      (format t "mlisp List Diagnosis Report~%")
      (format t "Generated: ~A~%~%" (mlisp:iso8601-now))
      (dolist (target (or siblings (list lst)))
        (let* ((tid          (getf target :id))
               (subs         (mlisp:list-subscribers tid))
               (active-subs  (remove-if (lambda (r) (getf r :nomail)) subs))
               (noml         (- (length subs) (length active-subs)))
               (pending      (mlisp:pending-entries tid))
               (bouncing     (remove-if-not
                               (lambda (r) (> (or (getf r :bounce-count) 0) 0))
                               subs))
               (tmpl-dir     (merge-pathnames "templates/" (mlisp:mlisp-home)))
               (missing-tpls (remove-if
                               (lambda (n)
                                 (probe-file (merge-pathnames
                                              (format nil "~A.~A.sexp" tid n)
                                              tmpl-dir)))
                               '("welcome" "goodbye" "help" "footer"))))
          (format t "List: ~A~%" tid)
          (format t "  subgroup:       ~A~%" (getf target :subgroup))
          (format t "  drop address:   ~A~%" (getf target :drop-address))
          (format t "  request addr:   ~A~%" (getf target :request-address))
          (format t "  subscribers:    ~A total (~A active, ~A NOMAIL, ~A pending confirm)~%"
                  (length subs) (length active-subs) noml (length pending))
          (format t "  bouncing:       ~A subscriber~:P with bounce-count > 0~%"
                  (length bouncing))
          (when bouncing
            (dolist (b bouncing)
              (format t "    ~A: ~A bounce~:P~%"
                      (or (getf b :address) "(hashed)")
                      (getf b :bounce-count))))
          (format t "  locked:         ~A~%" (if (getf target :locked) "YES - locked" "no"))
          (format t "  moderated:      ~A~%" (if (getf target :moderated) "yes" "no"))
          (format t "  delivery mode:  ~A~%" (or (getf target :delivery-mode) "individual"))
          (format t "  max msg size:   ~A~%"
                  (if (getf target :max-message-size-kb)
                      (format nil "~A KB" (getf target :max-message-size-kb))
                      "unlimited"))
          (format t "  confirm sub:    ~A~%"
                  (if (mlisp:confirm-subscribe-p tid) "yes (double opt-in)" "no (immediate)"))
          (format t "  non-member:     ~A~%"
                  (or (getf target :non-member-action) "reject"))
          (format t "  DMARC rewrite:  ~A~%"
                  (or (getf target :dmarc-rewrite) "none"))
          (format t "  VERP:           ~A~%" (if (getf target :verp) "enabled" "disabled"))
          (format t "  hash contacts:  ~A~%" (if (getf target :hash-contacts) "yes" "no"))
          (if missing-tpls
              (format t "  missing templates: ~{~A~^, ~}~%" missing-tpls)
              (format t "  templates:      all present~%"))
          (terpri)))
    0))


;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommands: embargo / release-embargo (#55)
;;; ─────────────────────────────────────────────────────────────────────────────

(define-admin-cmd embargo (list-id date) "<list-id> <ISO8601-date>"
  (mlisp:load-state)
  (let ((lst (mlisp:find-list list-id)))
    (unless lst (format *error-output* "mlisp-admin: unknown list ~A~%" list-id)
            (return-from cmd-embargo 1))
    (if (member :embargoed-until lst)
        (setf (getf lst :embargoed-until) date)
        (nconc lst (list :embargoed-until date)))
    (mlisp:save-state)
    (mlisp:audit-append (list :event :embargo-set :list list-id :until date))
    (format t "Embargoed ~A until ~A~%" list-id date)
    0))

(define-admin-cmd release-embargo (list-id) "<list-id>"
  (mlisp:load-state)
  (let ((lst (mlisp:find-list list-id)))
    (unless lst (format *error-output* "mlisp-admin: unknown list ~A~%" list-id)
            (return-from cmd-release-embargo 1))
    (remf lst :embargoed-until)
    ;; Distribute any held security posts
    (let ((held-path (merge-pathnames
                       (format nil "state/held/~A.sexp" list-id)
                       (mlisp:mlisp-home))))
      (when (probe-file held-path)
        (format t "Releasing held posts from ~A~%" held-path)))
    (mlisp:save-state)
    (mlisp:audit-append (list :event :embargo-released :list list-id))
    (format t "Released embargo on ~A~%" list-id)
    0))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: export-csv (#52)
;;; ─────────────────────────────────────────────────────────────────────────────

(defun cmd-export-csv (args)
  "export-csv <list-id> [--output file.csv] [--include-nomail] [--include-bounces]"
  (let ((list-id     (first args))
        (out-file    (let ((p (position "--output" args :test #'string=)))
                       (when p (nth (1+ p) args))))
        (incl-nomail (member "--include-nomail" args :test #'string=))
        (incl-bounce (member "--include-bounces" args :test #'string=)))
    (declare (ignore incl-bounce))
    (unless list-id
      (format *error-output* "mlisp-admin: export-csv requires <list-id>~%")
      (return-from cmd-export-csv 1))
    (mlisp:load-state)
    (let* ((subs  (mlisp:list-subscribers list-id))
           (hash? (getf (mlisp:find-list list-id) :hash-contacts))
           (csv
            (with-output-to-string (s)
              (format s "address,subscribed_at,consent_method,bounce_count,nomail,last_bounce_at~%")
              (dolist (sub subs)
                (when (or incl-nomail (not (getf sub :nomail)))
                  (format s "~A,~A,~A,~A,~A,~A~%"
                          (if hash?
                              (or (getf sub :address-hash) "")
                              (or (getf sub :address) ""))
                          (or (getf sub :subscribed-at) "")
                          (or (getf sub :consent-method) "")
                          (or (getf sub :bounce-count) 0)
                          (if (getf sub :nomail) "true" "false")
                          (or (getf sub :last-bounce-at) "")))))))
      (if out-file
          (progn
            (with-open-file (f out-file :direction :output
                                        :if-exists :supersede
                                        :if-does-not-exist :create)
              (write-string csv f))
            (format t "Exported ~A to ~A~%" list-id out-file))
          (write-string csv *standard-output*))
      0)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommands: rename-list, copy-list, list-stats (#53)
;;; ─────────────────────────────────────────────────────────────────────────────

(define-admin-cmd rename-list (old-id new-id) "<old-id> <new-id>"
  (mlisp:load-state)
  (let ((lst (mlisp:find-list old-id)))
    (unless lst (format *error-output* "mlisp-admin: unknown list ~A~%" old-id)
            (return-from cmd-rename-list 1))
    ;; Update id in-place
    (setf (getf lst :id) new-id)
    ;; Update drop-address: replace old-id prefix
    (let ((drop (getf lst :drop-address)))
      (when drop
        ;; Simple prefix replacement without regex dependency
        (setf (getf lst :drop-address)
              (if (and (>= (length drop) (length old-id))
                       (string= (subseq drop 0 (length old-id)) old-id))
                  (concatenate 'string new-id (subseq drop (length old-id)))
                  drop))))
    (mlisp:save-state)
    (mlisp:audit-append (list :event :list-renamed :old old-id :new new-id))
    (format t "Renamed ~A to ~A~%" old-id new-id)
    0))

(define-admin-cmd copy-list (src-id dst-id) "<src-id> <dst-id>"
  (mlisp:load-state)
  (let ((src-lst (mlisp:find-list src-id)))
    (unless src-lst (format *error-output* "mlisp-admin: unknown list ~A~%" src-id)
            (return-from cmd-copy-list 1))
    ;; Deep copy config, clear subscribers and counters
    (let ((new-lst (copy-list src-lst)))
      (setf (getf new-lst :id) dst-id)
      (setf (getf new-lst :subscribers) '())
      (setf (getf new-lst :message-counter) 0)
      ;; Append to the state list store
      (nconc mlisp:*state* (list new-lst))
      (mlisp:save-state))
    (format t "Copied config from ~A to ~A (subscribers not copied)~%" src-id dst-id)
    0))

(define-admin-cmd+ list-stats (list-id) ("--since") "<list-id>"
  (mlisp:load-state)
  (let* ((audit-path (merge-pathnames "state/audit.sexp" (mlisp:mlisp-home)))
         (events     (when (probe-file audit-path)
                       (with-open-file (s audit-path)
                         (loop for e = (ignore-errors (read s nil nil))
                               while e collect e))))
         ;; Filter to this list
         (list-events (remove-if-not
                        (lambda (e)
                          (and (string-equal (or (getf e :list) "") list-id)
                               (or (null since)
                                   (string>= (or (getf e :at) "") since))))
                        events))
         (distributed (count :distributed list-events :key (lambda (e) (getf e :event))))
         (held        (count :held         list-events :key (lambda (e) (getf e :event))))
         (subscribed  (count :subscribed   list-events :key (lambda (e) (getf e :event))))
         (unsubscribed (count :unsubscribed list-events :key (lambda (e) (getf e :event))))
         (bounced     (count :bounce-removed list-events :key (lambda (e) (getf e :event)))))
    (format t "Stats for ~A~@[ since ~A~]:~%" list-id since)
    (format t "  distributed:  ~A~%" distributed)
    (format t "  held:         ~A~%" held)
    (format t "  subscribed:   ~A~%" subscribed)
    (format t "  unsubscribed: ~A~%" unsubscribed)
    (format t "  bounced/removed: ~A~%" bounced)
    0))


;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: hatch (#65) — add file to distrib archive + announce
;;; ─────────────────────────────────────────────────────────────────────────────

(defun cmd-hatch (args)
  "hatch <list-id> <file> [--description 'text']
   Add FILE to the distrib archive for LIST-ID and optionally announce it."
  (let ((list-id (first args))
        (file    (second args))
        (desc    (let ((p (position "--description" args :test #'string=)))
                   (when p (nth (1+ p) args)))))
    (unless (and list-id file)
      (format *error-output* "mlisp-admin: hatch requires <list-id> <file>~%")
      (return-from cmd-hatch 1))
    (unless (probe-file file)
      (format *error-output* "mlisp-admin: file not found: ~A~%" file)
      (return-from cmd-hatch 1))
    (mlisp:load-state)
    (unless (mlisp:find-list list-id)
      (format *error-output* "mlisp-admin: unknown list ~A~%" list-id)
      (return-from cmd-hatch 1))
    (let ((dest (mlisp:add-file-to-distrib list-id file desc)))
      (format t "Hatched ~A into ~A~%" file list-id)
      (format t "Archive path: ~A~%" dest)
      0)))

(defun cmd-set-option (args)
  "Set a list option: set-option <list-id> <key> <value>"
  (destructuring-bind (&optional list-id key value &rest _) args
    (declare (ignore _))
    (unless (and list-id key value)
      (format *error-output* "mlisp-admin: set-option requires <list-id> <key> <value>~%")
      (return-from cmd-set-option 1))
    (mlisp:load-state)
    (let ((lst (mlisp:find-list list-id)))
      (unless lst
        (format *error-output* "mlisp-admin: unknown list ~A~%" list-id)
        (return-from cmd-set-option 1))
      (let* ((kw  (intern (string-upcase key) :keyword))
             (val (cond ((string-equal value "true")   t)
                        ((string-equal value "false")  nil)
                        ((string-equal key "delivery-mode")
                         (intern (string-upcase value) :keyword))
                        ((ignore-errors (parse-integer value)))
                        (t value))))
        ;; setf (getf lst kw) only mutates existing keys.
        ;; For new keys we must nconc onto the plist in *state*.
        (if (member kw lst)
            (setf (getf lst kw) val)
            (nconc lst (list kw val)))
        (mlisp:save-state)
        (format t "Set ~A :~A = ~S~%" list-id (string-downcase key) val)
        0))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: show-bounces
;;; ─────────────────────────────────────────────────────────────────────────────

(define-admin-cmd show-bounces (list-id) "<list-id>"
  (mlisp:load-state)
  (unless (mlisp:find-list list-id)
    (format *error-output* "mlisp-admin: unknown list ~A~%" list-id)
    (return-from cmd-show-bounces 1))
  (let ((found nil))
    (dolist (rec (mlisp:list-subscribers list-id))
      (let ((n (or (getf rec :bounce-count) 0)))
        (when (> n 0)
          (setf found t)
          (format t "~A  bounces=~A  last=~A~%"
                  (getf rec :address)
                  n
                  (or (getf rec :last-bounce) "never")))))
    (unless found (format t "No bounces recorded for ~A~%" list-id))
    0))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: clear-bounces
;;; ─────────────────────────────────────────────────────────────────────────────

(define-admin-cmd clear-bounces (list-id address) "<list-id> <address>"
  (mlisp:load-state)
  (mlisp:clear-bounce list-id address)
  (mlisp:save-state)
  (format t "Cleared bounces for ~A on ~A~%" address list-id)
  0)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: export-metrics
;;; ─────────────────────────────────────────────────────────────────────────────

(defun cmd-export-metrics ()
  (mlisp:load-state)
  (mlisp:write-metrics-file)
  (format t "Metrics written to ~A~%" (mlisp:metrics-path))
  0)


;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: show-dedup / clear-dedup
;;; ─────────────────────────────────────────────────────────────────────────────

(define-admin-cmd show-dedup (list-id) "<list-id>"
  (mlisp:load-state)
  (let ((entries (mlisp:dedup-entries list-id)))
    (if (null entries)
        (format t "No dedup entries for ~A~%" list-id)
        (dolist (e entries)
          (format t "~A  seen: ~A~%"
                  (getf e :id)
                  (getf e :seen-at))))
    0))

(define-admin-cmd clear-dedup (list-id) "<list-id>"
  (mlisp:load-state)
  (mlisp:clear-dedup-cache list-id)
  (format t "Cleared dedup cache for ~A~%" list-id)
  0)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: hold-queue / approve / reject
;;; ─────────────────────────────────────────────────────────────────────────────

(define-admin-cmd hold-queue (list-id) "<list-id>"
  (mlisp:load-state)
  (let ((queue (mlisp:held-queue list-id)))
    (if (null queue)
        (format t "No held messages for ~A~%" list-id)
        (dolist (e queue)
          (format t "~A  ~A  from: ~A  subj: ~A~%"
                  (getf e :seq)
                  (getf e :received)
                  (or (getf e :from) "")
                  (or (getf e :subject) ""))))
    0))

(define-admin-cmd approve (list-id seq-str) "<list-id> <seq>"
  (mlisp:load-state)
  (let* ((seq   (parse-integer seq-str))
         (entry (mlisp:release-held list-id seq)))
    (unless entry
      (format *error-output* "mlisp-admin: no held message ~A on ~A~%" seq list-id)
      (return-from cmd-approve 1))
    ;; Distribute the held message
    (let ((hdrs  (getf entry :headers))
          (body  (getf entry :body))
          (from  (getf entry :from)))
      (mlisp:maybe-archive-to-maildir list-id hdrs body)
      (mlisp:distribute-message list-id from hdrs body)
      (mlisp:audit-append (list :event :approved :list list-id :seq seq))
      (format t "Approved and distributed message ~A on ~A~%" seq list-id)
      0)))

(define-admin-cmd reject (list-id seq-str) "<list-id> <seq>"
  (mlisp:load-state)
  (let* ((seq   (parse-integer seq-str))
         (entry (mlisp:release-held list-id seq)))
    (unless entry
      (format *error-output* "mlisp-admin: no held message ~A on ~A~%" seq list-id)
      (return-from cmd-reject 1))
    (mlisp:audit-append (list :event :rejected-held :list list-id :seq seq))
    ;; Send rejection notice to original sender
    (let ((from (getf entry :from)))
      (when from
        (mlisp:sendmail (list (mlisp:extract-address from))
                        (format nil "Your submission to ~A was not approved.~%" list-id)
                        :extra-headers (list (cons "Subject"
                                                   (format nil "Submission rejected: ~A" list-id))
                                             (cons "From" (mlisp:list-drop-address list-id))))))
    (format t "Rejected message ~A on ~A~%" seq list-id)
    0))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: add-exploder
;;; ─────────────────────────────────────────────────────────────────────────────

(define-admin-cmd* add-exploder (id &rest members) "<id> <list-id> ..."
  (unless members
    (format *error-output* "mlisp-admin: add-exploder requires <id> <list-id> ...~%")
    (return-from cmd-add-exploder 1))
  (mlisp:load-state)
  (when (mlisp:find-list id)
    (format *error-output* "mlisp-admin: list ~A already exists~%" id)
    (return-from cmd-add-exploder 1))
  (setf (getf mlisp:*state* :lists)
        (append (getf mlisp:*state* :lists)
                (list (list :id id
                            :type :exploder
                            :drop-address (format nil "mlisp-exploder-~A@localhost" id)
                            :request-address (format nil "mlisp-exploder-~A-request@localhost" id)
                            :description (format nil "Exploder: ~{~A~^, ~}" members)
                            :member-lists members
                            :subscribers '()))))
  (mlisp:save-state)
  (format t "Created exploder ~A -> ~{~A~^, ~}~%" id members)
  0)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: flush-digest
;;; ─────────────────────────────────────────────────────────────────────────────

(define-admin-cmd flush-digest (list-id) "<list-id>"
  (mlisp:load-state)
  (let ((n (mlisp:flush-digest list-id)))
    (if (= n 0)
        (format t "Nothing to flush for ~A~%" list-id)
        (format t "Flushed ~A articles for ~A~%" n list-id))
    0))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: add-distrib
;;; ─────────────────────────────────────────────────────────────────────────────

(define-admin-cmd add-distrib (id path) "<id> <path>"
  (mlisp:load-state)
  (when (mlisp:find-list id)
    (format *error-output* "mlisp-admin: list ~A already exists~%" id)
    (return-from cmd-add-distrib 1))
  (setf (getf mlisp:*state* :lists)
        (append (getf mlisp:*state* :lists)
                (list (list :id id
                            :type :distrib
                            :drop-address (format nil "mlisp-distrib-~A@localhost" id)
                            :request-address (format nil "mlisp-distrib-~A-request@localhost" id)
                            :description (format nil "Distribution channel: ~A" id)
                            :distrib-path path
                            :max-file-size-kb 512
                            :subscribers '()))))
  (mlisp:save-state)
  (format t "Created distrib list ~A -> ~A~%" id path)
  0)

(defun usage ()
  (format t
"Usage: mlisp-admin [--home <dir>] <subcommand> [args...]

Options:
  --home <dir>   Config directory (overrides MLISP_HOME and XDG paths)

Subcommands:
  show-config                      print resolved config paths
  init [--dir <path>]              scaffold new config dir with seed state
  list-lists                       print all lists
  add-list <id> <drop> [<desc>]    add a new list
  rm-list  <id>                    remove a list
  list-subs <list-id>              print subscribers for a list
  add-sub  <list-id> <address>     add subscriber (consent: admin-add)
  rm-sub   <list-id> <address>     remove subscriber (GDPR erasure + audit)
  install-procmail [--list <id>] [--dry-run]  append procmail recipes to ~~/.procmailrc

Config resolution order:
  --home > $MLISP_HOME > $XDG_CONFIG_HOME/mlisp/ > ~~/.config/mlisp/ > binary dir
"))


;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommands: mlisp-bugs package management (#69, #70)
;;; ─────────────────────────────────────────────────────────────────────────────

(define-admin-cmd+ bugs-add-package (pkg submit) ("--owner") "<pkg> <submit-addr>"
  (handler-case
      (progn
        (mlisp:add-bugs-package pkg submit :owner-address owner)
        (format t "Registered bug package ~A (~A)~%" pkg submit)
        0)
    (error (e)
      (format *error-output* "mlisp-admin: ~A~%" e) 1)))

(define-admin-cmd bugs-list-packages () nil
  (mlisp:load-state)
  (let ((pkgs (mlisp:bugs-packages)))
    (if pkgs
        (dolist (p pkgs)
          (format t "~A  submit=~A  counter=~A  owner=~A~%"
                  (getf p :package)
                  (getf p :submit-address)
                  (getf p :bug-counter)
                  (or (getf p :owner-address) "(none)")))
        (format t "(no bug packages registered)~%"))
    0))

(define-admin-cmd bugs-show (pkg id-str) "<pkg> <id>"
  (let ((id (parse-integer id-str :junk-allowed t)))
    (unless id
      (format *error-output* "mlisp-admin: bugs-show requires <pkg> <id>~%")
      (return-from cmd-bugs-show 1))
    (mlisp:load-state)
    (let ((state (mlisp:bugs-derive-state pkg id)))
      (if state
          (progn
            (format t "Bug #~A: ~A~%" (getf state :id) (getf state :title))
            (format t "  Status:   ~(~A~)~%" (getf state :status))
            (format t "  Severity: ~A~%" (getf state :severity))
            (format t "  Tags:     ~{~A~^ ~}~%" (or (getf state :tags) '()))
            (format t "  Owner:    ~A~%" (or (getf state :owner) "(unassigned)"))
            (format t "  Reporter: ~A~%" (or (getf state :reported-by) ""))
            (format t "  Date:     ~A~%" (or (getf state :date) ""))
            0)
          (progn
            (format *error-output* "mlisp-admin: bug ~A #~A not found~%" pkg id)
            1)))))

(defun cmd-bugs-list (args)
  "bugs-list <pkg> [--open|--closed|--severity S|--tag T]"
  (let ((pkg      (first args))
        (open-only   (member "--open"   args :test #'string=))
        (closed-only (member "--closed" args :test #'string=))
        (sev-filter  (let ((p (position "--severity" args :test #'string=)))
                       (when p (nth (1+ p) args))))
        (tag-filter  (let ((p (position "--tag" args :test #'string=)))
                       (when p (nth (1+ p) args)))))
    (unless pkg
      (format *error-output* "mlisp-admin: bugs-list requires <pkg>~%")
      (return-from cmd-bugs-list 1))
    (mlisp:load-state)
    (let ((total (mlisp:bugs-package-counter pkg)))
      (loop for n from 1 to total
            for state = (mlisp:bugs-derive-state pkg n)
            when (and state
                      (or (not open-only)   (eq (getf state :status) :open))
                      (or (not closed-only) (eq (getf state :status) :closed))
                      (or (null sev-filter)
                          (string-equal (getf state :severity) sev-filter))
                      (or (null tag-filter)
                          (member tag-filter (getf state :tags) :test #'string-equal)))
            do (format t "#~3D [~7A] ~9A ~A~%"
                       (getf state :id)
                       (getf state :status)
                       (getf state :severity)
                       (getf state :title))))
    0))

(defun cmd-bugs-report (args)
  "bugs-report <pkg> [--open|--closed|--severity S|--tag T]"
  (let ((pkg      (first args))
        (open-only   (when (member "--open"   args :test #'string=) t))
        (closed-only (when (member "--closed" args :test #'string=) t))
        (sev-filter  (let ((p (position "--severity" args :test #'string=)))
                       (when p (nth (1+ p) args))))
        (tag-filter  (let ((p (position "--tag" args :test #'string=)))
                       (when p (nth (1+ p) args)))))
    (unless pkg
      (format *error-output* "mlisp-admin: bugs-report requires <pkg>~%")
      (return-from cmd-bugs-report 1))
    (mlisp:load-state)
    (write-string
     (mlisp:bugs-generate-report pkg
                                  :open-only   open-only
                                  :closed-only closed-only
                                  :severity-filter sev-filter
                                  :tag-filter      tag-filter))
    0))

(define-admin-cmd+ install-bugs-procmail (pkg) (("--dry-run" :boolean)) "<pkg>"
  (let* ((home     (mlisp:mlisp-home))
         (bugs-bin (merge-pathnames "bin/mlisp-bugs" home)))
    (mlisp:load-state)
    (let* ((pkg-cfg (mlisp:find-bugs-package pkg))
           (submit  (or (getf pkg-cfg :submit-address)
                        (format nil "~A-bugs-submit@example.com" pkg)))
           ;; Derive control address: strip -submit suffix, add -control
           (ctrl    (let* ((parts  (mlisp::split-string submit #\@))
                           (prefix (first parts))
                           ;; Remove trailing -submit if present
                           (base   (if (and (>= (length prefix) 7)
                                           (string= "-submit"
                                                    (subseq prefix (- (length prefix) 7))))
                                       (subseq prefix 0 (- (length prefix) 7))
                                       prefix)))
                      (format nil "~A-control@~A"
                              base
                              (or (second parts) "example.com"))))
           (recipes
            (format nil
                    "# mlisp-bugs: ~A~%~
                     :0~%~
                     * ^TO_~A~%~
                     | ~A --home ~A --mode submit ~A~%~%~
                     # mlisp-bugs: ~A (replies)~%~
                     :0~%~
                     * ^TO_~A-[0-9]+-done@~%~
                     | ~A --home ~A --mode close ~A~%~%~
                     :0~%~
                     * ^TO_~A-[0-9]+@~%~
                     | ~A --home ~A --mode append ~A~%~%~
                     # mlisp-bugs: ~A (control)~%~
                     :0~%~
                     * ^TO_~A~%~
                     | ~A --home ~A --mode control ~A~%~%"
                    pkg submit bugs-bin home pkg
                    pkg submit bugs-bin home pkg
                    submit bugs-bin home pkg
                    pkg ctrl bugs-bin home pkg)))
      (if dry-run
          (write-string recipes)
          (let ((procmailrc (merge-pathnames ".procmailrc" (user-homedir-pathname))))
            (with-open-file (f procmailrc :direction :output
                                          :if-exists :append
                                          :if-does-not-exist :create)
              (write-string recipes f))
            (format t "Appended ~A bug recipes to ~A~%" pkg procmailrc)))
      0)))

;;; Command dispatch table -- replaces 47-line cond chain
(defparameter *admin-commands*
  (list
   (cons "show-config" (lambda (_) (declare (ignore _)) (cmd-show-config)))
   (cons "init" #'cmd-init)
   (cons "list-lists" (lambda (_) (declare (ignore _)) (cmd-list-lists)))
   (cons "list-subs" #'cmd-list-subs)
   (cons "add-sub" #'cmd-add-sub)
   (cons "rm-sub" #'cmd-rm-sub)
   (cons "add-list" #'cmd-add-list)
   (cons "rm-list" #'cmd-rm-list)
   (cons "set-option" #'cmd-set-option)
   (cons "show-bounces" #'cmd-show-bounces)
   (cons "clear-bounces" #'cmd-clear-bounces)
   (cons "export-metrics" (lambda (_) (declare (ignore _)) (cmd-export-metrics)))
   (cons "show-dedup" #'cmd-show-dedup)
   (cons "clear-dedup" #'cmd-clear-dedup)
   (cons "hold-queue" #'cmd-hold-queue)
   (cons "approve" #'cmd-approve)
   (cons "reject" #'cmd-reject)
   (cons "add-exploder" #'cmd-add-exploder)
   (cons "flush-digest" #'cmd-flush-digest)
   (cons "add-distrib" #'cmd-add-distrib)
   (cons "add-namespace" #'cmd-add-namespace)
   (cons "list-namespace" #'cmd-list-namespace)
   (cons "set-nomail" #'cmd-set-nomail)
   (cons "lock" #'cmd-lock)
   (cons "unlock" #'cmd-unlock)
   (cons "show-pending" #'cmd-show-pending)
   (cons "clear-pending" #'cmd-clear-pending)
   (cons "add-sub-batch" #'cmd-add-sub-batch)
   (cons "rm-sub-batch" #'cmd-rm-sub-batch)
   (cons "export-ldif" #'cmd-export-ldif)
   (cons "verp-decode" #'cmd-verp-decode)
   (cons "diagnose" #'cmd-diagnose)
   (cons "embargo" #'cmd-embargo)
   (cons "release-embargo" #'cmd-release-embargo)
   (cons "export-csv" #'cmd-export-csv)
   (cons "rename-list" #'cmd-rename-list)
   (cons "copy-list" #'cmd-copy-list)
   (cons "list-stats" #'cmd-list-stats)
   (cons "bugs-add-package" #'cmd-bugs-add-package)
   (cons "bugs-list-packages" #'cmd-bugs-list-packages)
   (cons "install-procmail" #'cmd-install-procmail)
   (cons "bugs-list" #'cmd-bugs-list)
   (cons "bugs-show" #'cmd-bugs-show)
   (cons "bugs-report" #'cmd-bugs-report)
   (cons "install-bugs-procmail" #'cmd-install-bugs-procmail)
   (cons "hatch" #'cmd-hatch)
  ))

(defun admin-main ()
  "Entry point for mlisp-admin binary."
  (let ((args (cdr sb-ext:*posix-argv*)))
    (when (or (null args)
              (member "--help" args :test #'string=)
              (member "-h" args :test #'string=))
      (usage)
      (sb-ext:exit :code (if (null args) 1 0)))

    ;; Extract --home and --mode flags
    (multiple-value-bind (home-dir _mode remaining)
        (mlisp::parse-common-flags args)
      (declare (ignore _mode))
      (when home-dir
        (setf mlisp:*mlisp-home-override* home-dir))

      (when (null remaining)
        (usage)
        (sb-ext:exit :code 1))

      (let* ((subcmd (string-downcase (first remaining)))
             (subcmd-args (rest remaining))
             (code
              (handler-case
                  (let ((fn (cdr (assoc subcmd *admin-commands* :test #'string=))))
                    (if fn
                        (funcall fn subcmd-args)
                                                                                                                        (progn
                     (format *error-output*
                             "mlisp-admin: unknown subcommand ~S~%" subcmd)
                     (usage)
                     1)))
                (error (e)
                  (format *error-output* "mlisp-admin: fatal: ~A~%" e)
                  2))))
        (sb-ext:exit :code code)))))
