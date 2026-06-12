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
;;;; This is the shared printer + idempotency + file-write logic that
;;;; cmd-install-procmail and cmd-install-bugs-procmail each re-implemented
;;;; via ad-hoc format strings. Those commands are not yet refactored to
;;;; use this (separate follow-up); this module is the foundation for the
;;;; standalone mlisp-procmail-gen binary and for future filter-pipeline /
;;;; milter recipe generation.

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
