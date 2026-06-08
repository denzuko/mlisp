;;;; test/fiveam/test-mlisp.lisp — FiveAM unit tests for mlisp
;;;;
;;;; Run: sbcl --eval '(load "/home/claude/quicklisp/setup.lisp")' \
;;;;           --load test/fiveam/test-mlisp.lisp

;;; ── Quicklisp bootstrap ────────────────────────────────────────────────────
(let ((ql (merge-pathnames ".quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file ql) (load ql)))
(let ((ql "/home/claude/quicklisp/setup.lisp"))
  (when (probe-file ql) (load ql)))

(unless (find-package :fiveam)
  (handler-case (progn (require :fiveam))
    (error ()
      (handler-case (funcall (intern "QUICKLOAD" :ql) :fiveam :silent t)
        (error ()
          (format *error-output* "[SKIP] FiveAM not available.~%")
          (sb-ext:exit :code 77))))))

;;; ── Load mlisp source ──────────────────────────────────────────────────────
(let* ((here (directory-namestring (truename *load-pathname*)))
       ;; walk two levels up: test/fiveam/ -> test/ -> project root
       (root (namestring
              (truename
               (merge-pathnames "../../" (parse-namestring here)))))
       (src  (merge-pathnames "src/mlisp.lisp" root)))
  (load src))

;;; ── Test package ───────────────────────────────────────────────────────────
(defpackage #:mlisp-tests
  (:use #:cl #:fiveam))

(in-package #:mlisp-tests)

(def-suite mlisp-suite :description "mlisp core unit tests")
(in-suite  mlisp-suite)

;;; ────────────────────────────────────────────────────────────────────────────
;;; Header parser
;;; ────────────────────────────────────────────────────────────────────────────

(test header-parser-basic
  (let* ((lines '("From: alice@example.com"
                  "To: list@example.com"
                  "Subject: Hello"
                  ""
                  "Body here"))
         (hdrs (mlisp::parse-headers lines)))
    (is (string= "alice@example.com"
                 (cdr (assoc "FROM" hdrs :test #'string=))))
    (is (string= "Hello"
                 (cdr (assoc "SUBJECT" hdrs :test #'string=))))))

(test header-parser-folded
  (let* ((lines '("Subject: This is a very"
                  " long folded subject"
                  ""
                  "body"))
         (hdrs (mlisp::parse-headers lines)))
    (is (search "long folded"
                (cdr (assoc "SUBJECT" hdrs :test #'string=))))))

(test header-parser-stops-at-blank
  (let* ((lines '("From: x@y.com" "" "Not: a header"))
         (hdrs (mlisp::parse-headers lines)))
    (is (null (assoc "NOT" hdrs :test #'string=)))))

;;; ────────────────────────────────────────────────────────────────────────────
;;; Address extraction
;;; ────────────────────────────────────────────────────────────────────────────

(test extract-address-angle-brackets
  (is (string= "alice@example.com"
               (mlisp::extract-address "Alice Smith <alice@example.com>"))))

(test extract-address-plain
  (is (string= "bob@test.org"
               (mlisp::extract-address "  bob@test.org  "))))

(test extract-address-nil
  (is (null (mlisp::extract-address nil))))

;;; ────────────────────────────────────────────────────────────────────────────
;;; Command detection
;;; ────────────────────────────────────────────────────────────────────────────

(defun make-headers (pairs)
  (mapcar (lambda (p)
            (cons (string-upcase (car p)) (cdr p)))
          pairs))

(test detect-subscribe-in-subject
  (is (eq :subscribe
          (mlisp::detect-command
           (make-headers '(("Subject" . "subscribe me please")))
           '()))))

(test detect-unsubscribe-takes-priority
  (is (eq :unsubscribe
          (mlisp::detect-command
           (make-headers '(("Subject" . "please unsubscribe")))
           '()))))

(test detect-help-in-body
  (is (eq :help
          (mlisp::detect-command
           (make-headers '(("Subject" . "hi")))
           '("help")))))

(test detect-nil-for-regular-post
  (is (null (mlisp::detect-command
             (make-headers '(("Subject" . "Weekend meetup notes")))
             '("Great meeting everyone.")))))

;;; ────────────────────────────────────────────────────────────────────────────
;;; Subscriber management (in-memory state fixture)
;;; ────────────────────────────────────────────────────────────────────────────

(defmacro with-test-state (&body body)
  `(let ((mlisp::*state*
          '(:lists
            ((:id "discuss"
              :drop-address "denzuko+mlist-discuss@panix.com"
              :subscribers ("dwight@example.com" "alice@example.com"))
             (:id "devel"
              :drop-address "denzuko+mlist-devel@panix.com"
              :subscribers ())))))
     ,@body))

(test subscriber-present
  (with-test-state
    (is (mlisp::subscriber-p "discuss" "dwight@example.com"))
    (is (mlisp::subscriber-p "discuss" "DWIGHT@EXAMPLE.COM"))))

(test subscriber-absent
  (with-test-state
    (is (not (mlisp::subscriber-p "discuss" "stranger@evil.net")))))

(test add-subscriber-mutates-state
  (with-test-state
    (mlisp::add-subscriber "devel" "janet@example.com")
    (is (mlisp::subscriber-p "devel" "janet@example.com"))))

(test add-subscriber-idempotent
  (with-test-state
    (mlisp::add-subscriber "discuss" "dwight@example.com")
    (is (= 2 (length (mlisp::list-subscribers "discuss"))))))

(test remove-subscriber-mutates-state
  (with-test-state
    (mlisp::remove-subscriber "discuss" "alice@example.com")
    (is (not (mlisp::subscriber-p "discuss" "alice@example.com")))
    (is (mlisp::subscriber-p "discuss" "dwight@example.com"))))

;;; ────────────────────────────────────────────────────────────────────────────
;;; List metadata
;;; ────────────────────────────────────────────────────────────────────────────

(test find-list-returns-plist
  (with-test-state
    (let ((lst (mlisp::find-list "discuss")))
      (is (not (null lst)))
      (is (string= "denzuko+mlist-discuss@panix.com"
                   (getf lst :drop-address))))))

(test find-list-unknown-returns-nil
  (with-test-state
    (is (null (mlisp::find-list "nonexistent")))))

(test list-loop-header-format
  (is (string= "X-Loop-List-Discuss" (mlisp::list-loop-header "discuss")))
  (is (string= "X-Loop-List-Devel"   (mlisp::list-loop-header "devel")))
  (is (string= "X-Loop-List-Announce" (mlisp::list-loop-header "announce"))))

;;; ────────────────────────────────────────────────────────────────────────────
;;; troff DSL compilation
;;; ────────────────────────────────────────────────────────────────────────────

(test sexp->troff-paragraph
  (let ((out (mlisp::sexp->troff '(:p "Hello world"))))
    (is (search "Hello world" out))
    (is (search ".LP" out))))

(test sexp->troff-section
  (let ((out (mlisp::sexp->troff '(:section "Introduction"))))
    (is (search ".NH 1" out))
    (is (search "Introduction" out))))

(test sexp->troff-document-combines-blocks
  (let ((out (mlisp::sexp->troff
              '(:document
                (:title "Test Doc")
                (:p "First paragraph")
                (:section "A Section")
                (:pp "Second paragraph")))))
    (is (search "Test Doc" out))
    (is (search "First paragraph" out))
    (is (search "A Section" out))
    (is (search "Second paragraph" out))))

(test sexp->troff-bold-inline
  (let ((out (mlisp::sexp->troff '(:b "bold text"))))
    (is (search "bold text" out))
    (is (search "\\fB" out))))

(test sexp->troff-quote-block
  (let ((out (mlisp::sexp->troff '(:quote "quoted text"))))
    (is (search ".QS" out))
    (is (search "quoted text" out))
    (is (search ".QE" out))))

;;; ────────────────────────────────────────────────────────────────────────────
;;; groff rendering smoke test
;;; ────────────────────────────────────────────────────────────────────────────

(defun strip-overstrike (str)
  "Remove groff -Tutf8 bold overstrike sequences (X BS X) from STR."
  (with-output-to-string (out)
    (loop with i = 0
          while (< i (length str))
          do (let ((c (char str i)))
               (if (and (< (+ i 2) (length str))
                        (char= (char str (+ i 1)) #\Backspace))
                   (progn (write-char (char str (+ i 2)) out)
                          (incf i 3))
                   (progn (write-char c out)
                          (incf i)))))))

(test render-troff-produces-output
  (let* ((src (mlisp::sexp->troff
               '(:document
                 (:title "Smoke Test")
                 (:pp "If you see this it works."))))
         (rendered     (mlisp::render-troff-to-text src))
         (clean        (strip-overstrike rendered)))
    (is (> (length rendered) 0))
    (is (search "Smoke Test" clean))
    (is (search "If you see this it works" clean))))

;;; ────────────────────────────────────────────────────────────────────────────
;;; Run and exit
;;; ────────────────────────────────────────────────────────────────────────────

(let ((results (run 'mlisp-suite)))
  (explain! results)
  (sb-ext:exit :code (if (every #'fiveam::test-passed-p results) 0 1)))
