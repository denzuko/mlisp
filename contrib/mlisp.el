;;; mlisp.el --- Emacs interface to mlisp mailing list manager  -*- lexical-binding: t -*-

;; Author: Dwight Spencer <dwight@dapla.net>
;; Version: 0.6.0
;; Keywords: mail, lisp
;; URL: https://github.com/denzuko/mlisp
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:
;;
;; Administer mlisp mailing lists from Emacs.  Two backends:
;;
;;   Shell-out (default): calls mlisp-admin binary directly.
;;   SLIME/vlime: evaluates mlisp-admin functions in a connected image.
;;
;; Quick start:
;;
;;   (add-to-list 'load-path "/path/to/mlisp/contrib")
;;   (require 'mlisp)
;;   (setq mlisp-home "~/.config/mlisp")
;;
;; With use-package:
;;
;;   (use-package mlisp
;;     :load-path "~/src/mlisp/contrib"
;;     :custom
;;     (mlisp-home "~/.config/mlisp")
;;     (mlisp-admin-binary "/usr/local/bin/mlisp-admin"))
;;
;; To use SLIME instead of shell-out:
;;
;;   (setq mlisp-use-slime t)
;;   ;; Ensure mlisp is loaded in your SBCL image:
;;   ;; (asdf:load-system :mlisp-admin)

;;; Code:

(require 'cl-lib)

;;; ─── Customisation ───────────────────────────────────────────────────────────

(defgroup mlisp nil
  "Emacs interface to the mlisp mailing list manager."
  :group 'mail
  :prefix "mlisp-")

(defcustom mlisp-home
  (or (getenv "MLISP_HOME") "~/.config/mlisp")
  "Path to the mlisp state directory (MLISP_HOME)."
  :type 'directory
  :group 'mlisp)

(defcustom mlisp-admin-binary
  (or (executable-find "mlisp-admin") "/usr/local/bin/mlisp-admin")
  "Path to the mlisp-admin binary."
  :type 'file
  :group 'mlisp)

(defcustom mlisp-use-slime nil
  "When non-nil, evaluate commands via SLIME instead of shell-out.
Requires mlisp-admin to be loaded in the connected SBCL image:
  (asdf:load-system :mlisp-admin)"
  :type 'boolean
  :group 'mlisp)

(defcustom mlisp-buffer-name "*mlisp*"
  "Name of the mlisp output buffer."
  :type 'string
  :group 'mlisp)

;;; ─── Backend: shell-out ──────────────────────────────────────────────────────

(defun mlisp--run (&rest args)
  "Run mlisp-admin with ARGS and return output as string.
Sets MLISP_HOME from `mlisp-home'."
  (let ((process-environment
         (cons (format "MLISP_HOME=%s" (expand-file-name mlisp-home))
               process-environment)))
    (with-temp-buffer
      (apply #'call-process mlisp-admin-binary nil t nil
             "--home" (expand-file-name mlisp-home)
             args)
      (buffer-string))))

(defun mlisp--run-to-buffer (&rest args)
  "Run mlisp-admin with ARGS, display output in `mlisp-buffer-name'."
  (let ((output (apply #'mlisp--run args)))
    (with-current-buffer (get-buffer-create mlisp-buffer-name)
      (erase-buffer)
      (insert output)
      (goto-char (point-min)))
    (display-buffer mlisp-buffer-name)))

;;; ─── Backend: SLIME/vlime ────────────────────────────────────────────────────

(defun mlisp--slime-eval (form)
  "Evaluate FORM in the connected SLIME image and return result."
  (cond
   ((fboundp 'slime-eval)
    (slime-eval form))
   ((fboundp 'vlime-client-get-current)
    ;; vlime async — simplified synchronous wrapper
    (let ((result nil) (done nil))
      (vlime-eval form (lambda (r) (setq result r done t)))
      (while (not done) (sleep-for 0.05))
      result))
   (t
    (error "mlisp: neither SLIME nor vlime found.  \
Set mlisp-use-slime to nil to use shell-out backend."))))

(defun mlisp--eval-string (lisp-string)
  "Evaluate LISP-STRING via SLIME or shell-out depending on `mlisp-use-slime'."
  (if mlisp-use-slime
      (mlisp--slime-eval `(cl:progn
                            (mlisp:load-state)
                            ,(read lisp-string)))
    (error "mlisp--eval-string: use mlisp--run for shell-out backend")))

;;; ─── List helpers ────────────────────────────────────────────────────────────

(defun mlisp--list-ids ()
  "Return list of known mlisp list IDs."
  (if mlisp-use-slime
      (mlisp--slime-eval
       '(mapcar (lambda (l) (getf l :id))
                (getf mlisp:*state* :lists)))
    (split-string
     (shell-command-to-string
      (format "MLISP_HOME=%s %s --home %s list-lists 2>/dev/null | awk '{print $1}'"
              (expand-file-name mlisp-home)
              mlisp-admin-binary
              (expand-file-name mlisp-home)))
     "\n" t)))

(defun mlisp--read-list-id (&optional prompt)
  "Read a list ID from the user with completion."
  (completing-read (or prompt "List: ")
                   (mlisp--list-ids)
                   nil t))

;;; ─── Interactive commands ────────────────────────────────────────────────────

;;;###autoload
(defun mlisp-list-lists ()
  "Show all mlisp lists with subscriber counts."
  (interactive)
  (mlisp--run-to-buffer "list-lists"))

;;;###autoload
(defun mlisp-show-config (list-id)
  "Show configuration for LIST-ID."
  (interactive (list (mlisp--read-list-id "Show config for list: ")))
  (mlisp--run-to-buffer "show-config" list-id))

;;;###autoload
(defun mlisp-list-subs (list-id)
  "List subscribers for LIST-ID."
  (interactive (list (mlisp--read-list-id "List subscribers for: ")))
  (mlisp--run-to-buffer "list-subs" list-id))

;;;###autoload
(defun mlisp-hold-queue (list-id)
  "Show held message queue for LIST-ID."
  (interactive (list (mlisp--read-list-id "Hold queue for: ")))
  (mlisp--run-to-buffer "hold-queue" list-id))

;;;###autoload
(defun mlisp-approve (list-id seq)
  "Approve held message SEQ in LIST-ID."
  (interactive
   (let ((lid (mlisp--read-list-id "Approve from list: ")))
     (list lid (read-string (format "Approve message # in %s: " lid)))))
  (message "%s" (mlisp--run "approve" list-id seq)))

;;;###autoload
(defun mlisp-reject (list-id seq)
  "Reject held message SEQ in LIST-ID."
  (interactive
   (let ((lid (mlisp--read-list-id "Reject from list: ")))
     (list lid (read-string (format "Reject message # in %s: " lid)))))
  (message "%s" (mlisp--run "reject" list-id seq)))

;;;###autoload
(defun mlisp-add-sub (list-id address)
  "Add ADDRESS as subscriber to LIST-ID."
  (interactive
   (list (mlisp--read-list-id "Add subscriber to list: ")
         (read-string "Email address: ")))
  (message "%s" (mlisp--run "add-sub" list-id address)))

;;;###autoload
(defun mlisp-rm-sub (list-id address)
  "Remove ADDRESS from LIST-ID."
  (interactive
   (list (mlisp--read-list-id "Remove subscriber from list: ")
         (read-string "Email address to remove: ")))
  (when (yes-or-no-p (format "Remove %s from %s? " address list-id))
    (message "%s" (mlisp--run "rm-sub" list-id address))))

;;;###autoload
(defun mlisp-set-option (list-id key value)
  "Set option KEY to VALUE for LIST-ID."
  (interactive
   (let* ((lid (mlisp--read-list-id "Set option for list: "))
          (key (completing-read "Option key: "
                                '("dmarc-rewrite" "verp" "confirm-subscribe"
                                  "message-numbering" "max-posts-per-day"
                                  "attachment-policy" "subject-allow"
                                  "subject-deny" "unsubscribe-url"
                                  "archive-url" "search-enabled"
                                  "advertised" "pre-filter" "post-filter"
                                  "reply-to-munging" "non-member-action"
                                  "require-signed" "hash-contacts"
                                  "bot-address" "owner-address")))
          (val (read-string (format "Set %s to: " key))))
     (list lid key val)))
  (message "%s" (mlisp--run "set-option" list-id key value)))

;;;###autoload
(defun mlisp-diagnose (list-id)
  "Run diagnostics for LIST-ID."
  (interactive (list (mlisp--read-list-id "Diagnose list: ")))
  (mlisp--run-to-buffer "diagnose" list-id))

;;;###autoload
(defun mlisp-show-bounces (list-id)
  "Show subscribers with bounce counts for LIST-ID."
  (interactive (list (mlisp--read-list-id "Show bounces for: ")))
  (mlisp--run-to-buffer "show-bounces" list-id))

;;;###autoload
(defun mlisp-export-csv (list-id)
  "Export subscriber list for LIST-ID as CSV to a buffer."
  (interactive (list (mlisp--read-list-id "Export CSV for: ")))
  (let ((csv (mlisp--run "export-csv" list-id)))
    (with-current-buffer (get-buffer-create (format "*mlisp-csv-%s*" list-id))
      (erase-buffer)
      (insert csv)
      (csv-mode)
      (goto-char (point-min)))
    (display-buffer (format "*mlisp-csv-%s*" list-id))))

;;;###autoload
(defun mlisp-show-audit ()
  "Show the mlisp audit log, most recent events first."
  (interactive)
  (let ((audit-file (expand-file-name "state/audit.sexp" mlisp-home)))
    (if (file-readable-p audit-file)
        (progn
          (find-file-read-only audit-file)
          (goto-char (point-max)))
      (message "Audit log not found: %s" audit-file))))

;;;###autoload
(defun mlisp-lock (list-id)
  "Lock LIST-ID (hold all inbound posts)."
  (interactive (list (mlisp--read-list-id "Lock list: ")))
  (when (yes-or-no-p (format "Lock %s? (all posts will be held) " list-id))
    (message "%s" (mlisp--run "lock" list-id))))

;;;###autoload
(defun mlisp-unlock (list-id)
  "Unlock LIST-ID."
  (interactive (list (mlisp--read-list-id "Unlock list: ")))
  (message "%s" (mlisp--run "unlock" list-id)))

;;;###autoload
(defun mlisp-list-stats (list-id)
  "Show message and subscriber statistics for LIST-ID."
  (interactive (list (mlisp--read-list-id "Stats for: ")))
  (mlisp--run-to-buffer "list-stats" list-id))

;;; ─── Keymap ──────────────────────────────────────────────────────────────────

(defvar mlisp-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "l") #'mlisp-list-lists)
    (define-key map (kbd "c") #'mlisp-show-config)
    (define-key map (kbd "s") #'mlisp-list-subs)
    (define-key map (kbd "h") #'mlisp-hold-queue)
    (define-key map (kbd "a") #'mlisp-approve)
    (define-key map (kbd "r") #'mlisp-reject)
    (define-key map (kbd "+") #'mlisp-add-sub)
    (define-key map (kbd "-") #'mlisp-rm-sub)
    (define-key map (kbd "o") #'mlisp-set-option)
    (define-key map (kbd "d") #'mlisp-diagnose)
    (define-key map (kbd "b") #'mlisp-show-bounces)
    (define-key map (kbd "e") #'mlisp-export-csv)
    (define-key map (kbd "A") #'mlisp-show-audit)
    (define-key map (kbd "L") #'mlisp-lock)
    (define-key map (kbd "U") #'mlisp-unlock)
    (define-key map (kbd "S") #'mlisp-list-stats)
    map)
  "Keymap for mlisp commands.  Bind to a prefix key of your choice.")

;;;###autoload
(defun mlisp-setup-keys (prefix)
  "Bind mlisp commands under PREFIX key sequence.
Example: (mlisp-setup-keys \"C-c m\")"
  (global-set-key (kbd prefix) mlisp-command-map))

;;; ─── Minor mode ──────────────────────────────────────────────────────────────

;;;###autoload
(define-minor-mode mlisp-mode
  "Minor mode for mlisp administration.
With a prefix argument ARG, enable mlisp-mode if ARG is positive,
and disable it otherwise.  If called from Lisp, enable the mode if
ARG is omitted or nil.

Provides M-x mlisp-* commands for managing mlisp mailing lists.
See `mlisp-home', `mlisp-admin-binary', `mlisp-use-slime'."
  :lighter " mlisp"
  :keymap nil
  :global t
  :group 'mlisp)

(provide 'mlisp)

;;; mlisp.el ends here
