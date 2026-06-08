;;;; test/fiveam/test-mlisp-mime.lisp — FiveAM unit tests for MIME processing
;;;;
;;;; Run: sbcl --eval '(load "/home/claude/quicklisp/setup.lisp")'
;;;;          --eval '(ql:quickload :fiveam :silent t)'
;;;;          --eval '(push (truename ".") asdf:*central-registry*)'
;;;;          --load test/fiveam/test-mlisp-mime.lisp

(let ((ql "/home/claude/quicklisp/setup.lisp"))
  (when (probe-file ql) (load ql)))

(unless (find-package :fiveam)
  (handler-case (funcall (intern "QUICKLOAD" :ql) :fiveam :silent t)
    (error () (sb-ext:exit :code 77))))

(let* ((here (directory-namestring (truename *load-pathname*)))
       (root (namestring (truename (merge-pathnames "../../" (parse-namestring here))))))
  (unless (find-package :mlisp)
    (pushnew (truename root) asdf:*central-registry* :test #'equal)
    (asdf:load-system :mlisp)))

(defpackage #:mlisp-mime-tests
  (:use #:cl #:fiveam))

(in-package #:mlisp-mime-tests)

(def-suite mime-suite :description "MIME inbound stripping unit tests")
(in-suite  mime-suite)

;;; ── HTML entity stripping ────────────────────────────────────────────────

(test strip-html-tags-basic
  (is (string= "Hello world"
               (mlisp::strip-html "Hello world"))))

(test strip-html-tags-bold
  (is (string= "Hello world"
               (mlisp::strip-html "<b>Hello</b> world"))))

(test strip-html-tags-anchor
  (is (search "Click here"
              (mlisp::strip-html "<a href=\"http://example.com\">Click here</a>"))))

(test strip-html-entities-amp
  (is (string= "A & B"
               (mlisp::decode-html-entities "A &amp; B"))))

(test strip-html-entities-lt-gt
  (let ((result (mlisp::decode-html-entities "a &lt;b&gt; c")))
    (is (search "<b>" result))))

(test strip-html-entities-nbsp
  (let ((result (mlisp::decode-html-entities "a&nbsp;b")))
    (is (> (length result) 2))))

(test strip-html-full-document
  (let* ((html "<html><body><p>Hello <b>world</b></p><br/></body></html>")
         (result (mlisp::strip-html html)))
    (is (search "Hello" result))
    (is (search "world" result))
    (is (not (search "<" result)))))

;;; ── MIME boundary detection ──────────────────────────────────────────────

(test mime-boundary-from-content-type
  (let ((ct "multipart/alternative; boundary=\"----=_Part_123\""))
    (is (string= "----=_Part_123"
                 (mlisp::extract-mime-boundary ct)))))

(test mime-boundary-nil-for-non-multipart
  (is (null (mlisp::extract-mime-boundary "text/plain; charset=utf-8"))))

(test mime-boundary-nil-for-nil
  (is (null (mlisp::extract-mime-boundary nil))))

;;; ── Content-Type detection ───────────────────────────────────────────────

(test mime-type-text-plain
  (is (eq :text-plain
          (mlisp::classify-content-type "text/plain"))))

(test mime-type-text-html
  (is (eq :text-html
          (mlisp::classify-content-type "text/html; charset=utf-8"))))

(test mime-type-multipart-alternative
  (is (eq :multipart-alternative
          (mlisp::classify-content-type "multipart/alternative; boundary=foo"))))

(test mime-type-multipart-mixed
  (is (eq :multipart-mixed
          (mlisp::classify-content-type "multipart/mixed; boundary=foo"))))

(test mime-type-unknown
  (is (eq :unknown
          (mlisp::classify-content-type "application/pdf"))))

;;; ── Full MIME extraction ─────────────────────────────────────────────────

(defparameter *multipart-alternative-email*
  "From: sender@example.com
To: list@example.com
Subject: Test
MIME-Version: 1.0
Content-Type: multipart/alternative; boundary=\"boundary123\"

--boundary123
Content-Type: text/plain; charset=utf-8

This is the plain text part.

--boundary123
Content-Type: text/html; charset=utf-8

<html><body><p>This is the <b>HTML</b> part.</p></body></html>

--boundary123--
")

(defparameter *html-only-email*
  "From: sender@example.com
Subject: HTML only
MIME-Version: 1.0
Content-Type: text/html; charset=utf-8

<html><body><p>Hello <b>world</b></p></body></html>
")

(defparameter *plain-email*
  "From: sender@example.com
Subject: Plain
Content-Type: text/plain

Just plain text here.
")

(test extract-plain-from-multipart-alternative
  (let ((result (mlisp::mime-extract-text *multipart-alternative-email*)))
    (is (search "plain text part" result))
    (is (not (search "<html>" result)))))

(test plain-preferred-over-html-in-multipart
  (let ((result (mlisp::mime-extract-text *multipart-alternative-email*)))
    ;; Must use text/plain, not HTML part
    (is (not (search "<b>" result)))))

(test extract-text-from-html-only
  (let ((result (mlisp::mime-extract-text *html-only-email*)))
    (is (search "Hello" result))
    (is (search "world" result))
    (is (not (search "<html>" result)))))

(test plain-text-passthrough
  (let ((result (mlisp::mime-extract-text *plain-email*)))
    (is (search "Just plain text" result))))

(test outbound-body-contains-no-html-after-processing
  ;; Process a multipart message and confirm outbound body is clean
  (let* ((lines (with-input-from-string (s *multipart-alternative-email*)
                  (loop for l = (read-line s nil nil) while l collect l)))
         (sep   (position "" lines :test #'string=))
         (hdrs  (mlisp::parse-headers (subseq lines 0 sep)))
         (body  (subseq lines (1+ sep)))
         (ct    (mlisp::header-value hdrs "Content-Type"))
         (text  (mlisp::process-body-for-distribution hdrs body)))
    (declare (ignore ct))
    (is (not (search "<" text)))))

;;; ── Run ──────────────────────────────────────────────────────────────────

(let ((results (run 'mime-suite)))
  (explain! results)
  (sb-ext:exit :code (if (every #'fiveam::test-passed-p results) 0 1)))
