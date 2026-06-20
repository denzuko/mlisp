;;;; src/procmail-gen.lisp -- mlisp-procmail-gen: s-expr DSL for procmailrc
;;;;
;;;; A "recipe" is plain data:
;;;;
;;;;   (:recipe :marker  "mlisp: mlisp-discuss"
;;;;            :guards  ("!^FROM_DAEMON" "!^FROM_MAILER"
;;;;                      "!^Precedence: (bulk|junk|list)")
;;;;            :match   "^^TO_mlisp-discuss@panix.com"
;;;;            :pipe    "/usr/local/bin/mlisp --home /etc/mlisp ")
;;;;
;;;; A "recipe set" is a list of :recipe forms, printed in order with
;;;; blank-line separation -- the unit normally written for one list
;;;; or one bug package (e.g. mlisp's list + -request sibling, or
;;;; mlisp-bugs' submit/close/append/control quartet).
;;;;
;;;; recipe->procmailrc, recipe-set->procmailrc, write-procmail-recipes,
;;;; and list-recipes / bugs-recipes are the shared primitives used by
;;;; cmd-install-procmail, cmd-install-bugs-procmail, and the standalone
;;;; mlisp-procmail-gen binary.

(in-package #:mlisp)

;;; ─── Printer ──────────────────────────────────────────────────────────────

(defun recipe->procmailrc (recipe)
  "Render a single (:recipe :marker M :guards (...) :match S :pipe CMD) form
   as a procmail recipe block, terminated by a blank line. RECIPE may be
   given with or without its leading :recipe tag."
  (let* ((plist  (if (eq (first recipe) :recipe) (rest recipe) recipe))
         (marker (getf plist :marker))
         (guards (getf plist :guards))
         (match  (getf plist :match))
         (pipe   (getf plist :pipe)))
    (with-output-to-string (s)
      (when marker
        (format s "# ~A~%" marker))
      (write-line ":0" s)
      (dolist (g guards)
        (format s "* ~A~%" g))
      (format s "* ~A~%" match)
      (format s "| ~A~%" pipe)
      (terpri s))))

(defun recipe-set->procmailrc (recipes)
  "Render a list of :recipe plists as concatenated procmail blocks."
  (apply #'concatenate 'string (mapcar #'recipe->procmailrc recipes)))

;;; ─── Idempotency ──────────────────────────────────────────────────────────

(defun procmailrc-has-marker-p (path marker)
  "Return T if the file at PATH already contains a line \"# MARKER\"
   (generalizes the per-list mlisp:-prefixed marker check)."
  (when (probe-file path)
    (with-open-file (s path :direction :input)
      (let ((needle (format nil "# ~A" marker)))
        (loop for line = (read-line s nil nil)
              while line
              when (string= line needle)
              return t)))))

;;; ─── Recipe file I/O ──────────────────────────────────────────────────────

(defun read-recipes-from-file (path)
  "Read all top-level forms from PATH. Each form is expected to be a
   (:recipe ...) plist or a (:recipe-set (:recipe ...) (:recipe ...) ...)
   form; the latter is flattened. Returns a flat list of :recipe plists."
  (let ((forms '()))
    (with-open-file (s path :direction :input)
      (loop for form = (read s nil :eof)
            until (eq form :eof)
            do (push form forms)))
    (setf forms (nreverse forms))
    (mapcan (lambda (form)
              (if (eq (first form) :recipe-set)
                  (rest form)
                  (list form)))
            forms)))

;;; ─── Write/install logic (shared by procmail-gen and future refactors) ────

(defun write-procmail-recipes (recipes procmailrc-path &key dry-run)
  "For each recipe in RECIPES, skip if PROCMAILRC-PATH already contains
   its :marker; otherwise append (or, if DRY-RUN, print what would be
   appended). Returns the count of recipes actually written."
  (let ((written 0))
    (dolist (recipe recipes)
      (let* ((plist  (if (eq (first recipe) :recipe) (rest recipe) recipe))
             (marker (getf plist :marker)))
        (cond
          ((procmailrc-has-marker-p procmailrc-path marker)
           (if dry-run
               (format t "# SKIP (already present): ~A~%~%" marker)
               (format t "Skipped ~A (already in ~A)~%" marker procmailrc-path)))
          (dry-run
           (write-string (recipe->procmailrc recipe)))
          (t
           (with-open-file (f procmailrc-path :direction :output
                                              :if-exists :append
                                              :if-does-not-exist :create)
             (write-string (recipe->procmailrc recipe) f))
           (format t "Added ~A -> ~A~%" marker procmailrc-path)
           (incf written)))))
    written))

;;; ─── Recipe builders (used by admin install commands) ─────────────────────

(defun list-recipes (list-id drop-address mlisp-bin home-dir)
  "Return a list of :recipe plists for LIST-ID.
   For a :request subgroup: one recipe with --mode request.
   For all other subgroups: two recipes -- the list delivery recipe
   and its sibling -request command recipe."
  (let* ((sg      (list-subgroup list-id))
         (is-req  (eq sg :request))
         (at-pos  (position #\@ drop-address))
         (local   (if at-pos (subseq drop-address 0 at-pos) drop-address))
         (domain  (if at-pos (subseq drop-address at-pos) ""))
         (req-drop (concatenate 'string local "-request" domain))
         (guards  '("!^FROM_DAEMON" "!^FROM_MAILER"
                    "!^Precedence: (bulk|junk|list)"))
         (pipe-list (format nil "~A --home ~A ~A"
                            mlisp-bin home-dir list-id))
         (pipe-req  (format nil "~A --home ~A --mode request ~A"
                            mlisp-bin home-dir list-id)))
    (if is-req
        (list (list :recipe
                    :marker  (format nil "mlisp: ~A" list-id)
                    :guards  guards
                    :match   (format nil "^^TO_~A" drop-address)
                    :pipe    pipe-req))
        (list (list :recipe
                    :marker  (format nil "mlisp: ~A" list-id)
                    :guards  guards
                    :match   (format nil "^^TO_~A" drop-address)
                    :pipe    pipe-list)
              (list :recipe
                    :marker  (format nil "mlisp: ~A-request" list-id)
                    :guards  '()
                    :match   (format nil "^^TO_~A" req-drop)
                    :pipe    pipe-req)))))

(defun bugs-recipes (pkg submit-addr ctrl-addr bugs-bin home-dir)
  "Return a list of :recipe plists for a mlisp-bugs package PKG.
   Covers submit, close (reply to bug#N-done), append (reply to bug#N),
   and control addresses."
  (let ((at-pos  (position #\@ submit-addr))
        (guards  '("!^FROM_DAEMON" "!^FROM_MAILER")))
    (let* ((local  (if at-pos (subseq submit-addr 0 at-pos) submit-addr))
           (domain (if at-pos (subseq submit-addr at-pos) ""))
           (done-match (format nil "^^TO_~A-[0-9]+-done~A" local domain))
           (num-match  (format nil "^^TO_~A-[0-9]+~A"      local domain)))
      (list
       (list :recipe
             :marker  (format nil "mlisp-bugs: ~A" pkg)
             :guards  guards
             :match   (format nil "^^TO_~A" submit-addr)
             :pipe    (format nil "~A --home ~A --mode submit ~A"
                              bugs-bin home-dir pkg))
       (list :recipe
             :marker  (format nil "mlisp-bugs: ~A (replies)" pkg)
             :guards  guards
             :match   done-match
             :pipe    (format nil "~A --home ~A --mode close ~A"
                              bugs-bin home-dir pkg))
       (list :recipe
             :marker  (format nil "mlisp-bugs: ~A (append)" pkg)
             :guards  guards
             :match   num-match
             :pipe    (format nil "~A --home ~A --mode append ~A"
                              bugs-bin home-dir pkg))
       (list :recipe
             :marker  (format nil "mlisp-bugs: ~A (control)" pkg)
             :guards  guards
             :match   (format nil "^^TO_~A" ctrl-addr)
             :pipe    (format nil "~A --home ~A --mode control ~A"
                              bugs-bin home-dir pkg))))))
