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

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Seed data for init subcommand
;;; ─────────────────────────────────────────────────────────────────────────────

(defparameter *seed-state*
  '(:lists
    ((:id "discuss"
      :drop-address "user+mlist-discuss@example.com"
      :description "General discussion list"
      :postal-address "Your Organization, 123 Main St, City ST 00000, USA"
      :privacy-url "https://example.com/privacy"
      :subscribers ())
     (:id "announce"
      :drop-address "user+mlist-announce@example.com"
      :description "Announcements list"
      :postal-address "Your Organization, 123 Main St, City ST 00000, USA"
      :privacy-url "https://example.com/privacy"
      :subscribers ())
     (:id "devel"
      :drop-address "user+mlist-devel@example.com"
      :description "Development list"
      :postal-address "Your Organization, 123 Main St, City ST 00000, USA"
      :privacy-url "https://example.com/privacy"
      :subscribers ())))
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

(defun cmd-list-subs (args)
  (let ((list-id (first args)))
    (unless list-id
      (format *error-output* "mlisp-admin: list-subs requires <list-id>~%")
      (return-from cmd-list-subs 1))
    (mlisp:load-state)
    (let ((lst (mlisp:find-list list-id)))
      (unless lst
        (format *error-output* "mlisp-admin: unknown list ~A~%" list-id)
        (return-from cmd-list-subs 1))
      (let ((subs (mlisp:list-subscribers list-id)))
        (if (null subs)
            (format t "No subscribers on ~A.~%" list-id)
            (dolist (rec subs)
              (format t "~A~%  subscribed-at: ~A~%  consent-method: ~A~%"
                      (getf rec :address)
                      (getf rec :subscribed-at)
                      (getf rec :consent-method)))))
      0)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: add-sub
;;; ─────────────────────────────────────────────────────────────────────────────

(defun cmd-add-sub (args)
  (destructuring-bind (&optional list-id address &rest _) args
    (declare (ignore _))
    (unless (and list-id address)
      (format *error-output* "mlisp-admin: add-sub requires <list-id> <address>~%")
      (return-from cmd-add-sub 1))
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
    0))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: rm-sub
;;; ─────────────────────────────────────────────────────────────────────────────

(defun cmd-rm-sub (args)
  (destructuring-bind (&optional list-id address &rest _) args
    (declare (ignore _))
    (unless (and list-id address)
      (format *error-output* "mlisp-admin: rm-sub requires <list-id> <address>~%")
      (return-from cmd-rm-sub 1))
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
    0))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: add-list
;;; ─────────────────────────────────────────────────────────────────────────────

(defun cmd-add-list (args)
  (destructuring-bind (&optional id drop desc &rest _) args
    (declare (ignore _))
    (unless (and id drop)
      (format *error-output*
              "mlisp-admin: add-list requires <id> <drop-address> [<description>]~%")
      (return-from cmd-add-list 1))
    (mlisp:load-state)
    (when (mlisp:find-list id)
      (format *error-output* "mlisp-admin: list ~A already exists~%" id)
      (return-from cmd-add-list 1))
    (setf (getf mlisp:*state* :lists)
          (append (getf mlisp:*state* :lists)
                  (list (list :id id
                              :drop-address drop
                              :description (or desc "")
                              :postal-address
                              (mlisp:list-postal-address "discuss") ; inherit default
                              :privacy-url
                              (mlisp:list-privacy-url "discuss")
                              :subscribers '()))))
    (mlisp:save-state)
    (format t "Created list ~A -> ~A~%" id drop)
    0))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: rm-list
;;; ─────────────────────────────────────────────────────────────────────────────

(defun cmd-rm-list (args)
  (let ((id (first args)))
    (unless id
      (format *error-output* "mlisp-admin: rm-list requires <id>~%")
      (return-from cmd-rm-list 1))
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
    0))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Admin entry point
;;; ─────────────────────────────────────────────────────────────────────────────


;;; ─────────────────────────────────────────────────────────────────────────────
;;; Subcommand: install-procmail
;;; ─────────────────────────────────────────────────────────────────────────────

(defun procmail-recipe (list-id drop-address mlisp-bin home-dir)
  "Return a procmail recipe string for LIST-ID.
   The comment line '# mlisp: <id>' is the idempotency marker."
  (format nil
"# mlisp: ~A
:0
* ^^TO_~A
| ~A --home ~A ~A
"
          list-id drop-address mlisp-bin home-dir list-id))

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

(defun admin-main ()
  "Entry point for mlisp-admin binary."
  (let ((args (cdr sb-ext:*posix-argv*)))
    (when (or (null args)
              (member "--help" args :test #'string=)
              (member "-h" args :test #'string=))
      (usage)
      (sb-ext:exit :code (if (null args) 1 0)))

    ;; Extract --home flag
    (multiple-value-bind (home-dir remaining)
        (mlisp::parse-common-flags args)
      (when home-dir
        (setf mlisp:*mlisp-home-override* home-dir))

      (when (null remaining)
        (usage)
        (sb-ext:exit :code 1))

      (let* ((subcmd (string-downcase (first remaining)))
             (subcmd-args (rest remaining))
             (code
              (handler-case
                  (cond
                    ((string= subcmd "show-config")  (cmd-show-config))
                    ((string= subcmd "init")         (cmd-init subcmd-args))
                    ((string= subcmd "list-lists")   (cmd-list-lists))
                    ((string= subcmd "list-subs")    (cmd-list-subs subcmd-args))
                    ((string= subcmd "add-sub")      (cmd-add-sub subcmd-args))
                    ((string= subcmd "rm-sub")       (cmd-rm-sub subcmd-args))
                    ((string= subcmd "add-list")     (cmd-add-list subcmd-args))
                    ((string= subcmd "rm-list")      (cmd-rm-list subcmd-args))
                    ((string= subcmd "install-procmail")
                                              (cmd-install-procmail subcmd-args))
                    (t
                     (format *error-output*
                             "mlisp-admin: unknown subcommand ~S~%" subcmd)
                     (usage)
                     1))
                (error (e)
                  (format *error-output* "mlisp-admin: fatal: ~A~%" e)
                  2))))
        (sb-ext:exit :code code)))))
