;;;; src/procmail-gen-main.lisp -- mlisp-procmail-gen binary entry point
;;;;
;;;; Usage:
;;;;   mlisp-procmail-gen <recipe-file.lisp>
;;;;   mlisp-procmail-gen --dry-run <recipe-file.lisp>
;;;;   mlisp-procmail-gen --output <path> <recipe-file.lisp>
;;;;
;;;; <recipe-file.lisp> contains one or more top-level forms:
;;;;
;;;;   (:recipe :marker "mlisp: mlisp-discuss"
;;;;            :guards ("!^FROM_DAEMON" "!^FROM_MAILER")
;;;;            :match  "^^TO_mlisp-discuss@panix.com"
;;;;            :pipe   "/usr/local/bin/mlisp --home /etc/mlisp ")
;;;;
;;;; or a (:recipe-set (:recipe ...) (:recipe ...) ...) grouping form.
;;;;
;;;; Without --output, recipes are printed to stdout (one full procmailrc
;;;; fragment). With --output <path>, recipes are appended to <path>,
;;;; skipping any whose :marker is already present (idempotent), exactly
;;;; like cmd-install-procmail / cmd-install-bugs-procmail.

(defpackage #:mlisp-procmail-gen-main
  (:use #:cl #:mlisp)
  (:shadow #:main)
  (:export #:main))

(in-package #:mlisp-procmail-gen-main)

(defun usage ()
  (format *error-output*
"Usage: mlisp-procmail-gen [--output <path>] [--dry-run] <recipe-file.lisp>

  --output <path>   append generated recipes to <path> (idempotent via
                     the \"# <marker>\" comment line); default: print to stdout
  --dry-run         with --output, show what would be appended without
                     writing (has no effect without --output)
"))

(defun main ()
  (let* ((argv       (rest sb-ext:*posix-argv*))
         (out-idx    (position "--output" argv :test #'string=))
         (output     (when out-idx (nth (1+ out-idx) argv)))
         (dry-run    (and (member "--dry-run" argv :test #'string=) t))
         (pos-args   (remove-if (lambda (a)
                                  (or (string= a "--output")
                                      (string= a "--dry-run")
                                      (equal a output)))
                                 argv))
         (recipe-file (first pos-args)))

    (when (or (null recipe-file)
              (member recipe-file '("--help" "-h") :test #'string=))
      (usage)
      (sb-ext:exit :code (if recipe-file 0 1)))

    (unless (probe-file recipe-file)
      (format *error-output* "mlisp-procmail-gen: no such file: ~A~%" recipe-file)
      (sb-ext:exit :code 1))

    (let ((recipes (mlisp:read-recipes-from-file recipe-file)))
      (if output
          (mlisp:write-procmail-recipes recipes output :dry-run dry-run)
          (write-string (mlisp:recipe-set->procmailrc recipes))))

    (sb-ext:exit :code 0)))
