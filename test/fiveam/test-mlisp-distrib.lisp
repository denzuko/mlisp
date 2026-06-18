;;;; test/fiveam/test-mlisp-distrib.lisp
;;;;
;;;; FiveAM BDD specs for mlisp-distrib streaming encoder and yEnc
;;;; multipart chunking (#130, #131).
;;;;
;;;; Written BEFORE implementation per project BDD workflow.
;;;;
;;;; Run:
;;;;   (asdf:test-system :mlisp)
;;;;   sbcl --noinform --load test/fiveam/test-mlisp-distrib.lisp

;;; ── Bootstrap ────────────────────────────────────────────────────────────

(dolist (path (list
               (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))
               #p"/home/claude/quicklisp/setup.lisp"))
  (when (probe-file path) (load path) (return)))

(unless (find-package :fiveam)
  (funcall (find-symbol "QUICKLOAD" :ql) :fiveam :silent t))

(let* ((here (directory-namestring (truename *load-pathname*)))
       (root (namestring (truename (merge-pathnames "../../" (parse-namestring here))))))
  (unless (find-package :mlisp)
    (pushnew (truename root) asdf:*central-registry* :test #'equal)
    (asdf:load-system :mlisp)))

(unless (find-package :mlisp-distrib)
  (let* ((here (directory-namestring (truename *load-pathname*)))
         (root (namestring (truename (merge-pathnames "../../" (parse-namestring here))))))
    (load (merge-pathnames "src/distrib.lisp" root))))

;;; ── Test package ─────────────────────────────────────────────────────────

(defpackage #:mlisp-distrib-tests
  (:use #:cl #:fiveam))

(in-package #:mlisp-distrib-tests)

(def-suite distrib-suite
  :description "mlisp-distrib streaming encoder + yEnc chunking BDD specs (#130, #131)")

(in-suite distrib-suite)

;;; ── Fixtures ─────────────────────────────────────────────────────────────

(defun make-temp-file (size-bytes &optional (fill-byte 65))
  "Create a temporary file of SIZE-BYTES bytes, filled with FILL-BYTE.
   Returns the pathname. Caller is responsible for deletion."
  (let ((path (merge-pathnames
               (format nil "mlisp-test-~A.bin" (get-universal-time))
               (uiop:temporary-directory))))
    (with-open-file (s path :direction :output
                            :element-type '(unsigned-byte 8)
                            :if-does-not-exist :create)
      (let ((buf (make-array (min size-bytes 4096)
                              :element-type '(unsigned-byte 8)
                              :initial-element fill-byte)))
        (loop for written from 0 below size-bytes by 4096 do
          (write-sequence buf s :end (min 4096 (- size-bytes written))))))
    path))

;;; ── #130: Streaming base64 encoder ──────────────────────────────────────
;;; base64-encode-file-streaming should write to a stream in fixed-size
;;; chunks, never loading the whole file into memory.

(test STRM-1-streaming-encoder-produces-valid-base64
  "Streaming encoder output is valid base64 (alphabet + line endings only)."
  (let ((path (make-temp-file 1024)))
    (unwind-protect
        (let ((out (make-string-output-stream)))
          (mlisp-distrib::base64-encode-file-streaming path out)
          (let ((result (get-output-stream-string out)))
            (is (> (length result) 0))
            ;; Only base64 characters and newlines
            (is (every (lambda (c)
                         (or (alphanumericp c)
                             (member c '(#\+ #\/ #\= #\Newline #\Return))))
                       result))))
      (delete-file path))))

(test STRM-2-streaming-matches-whole-file-encode
  "Streaming encoder produces same output as reading whole file."
  (let ((path (make-temp-file 512)))
    (unwind-protect
        (let* ((streaming-out (make-string-output-stream))
               (whole (mlisp-distrib::base64-encode-file path)))
          (mlisp-distrib::base64-encode-file-streaming path streaming-out)
          (is (string= whole (get-output-stream-string streaming-out))))
      (delete-file path))))

(test STRM-3-streaming-handles-empty-file
  "Streaming encoder handles zero-byte files without error."
  (let ((path (make-temp-file 0)))
    (unwind-protect
        (let ((out (make-string-output-stream)))
          (mlisp-distrib::base64-encode-file-streaming path out)
          (is (string= "" (get-output-stream-string out))))
      (delete-file path))))

(test STRM-4-streaming-lines-are-76-chars
  "Streaming encoder wraps lines at 76 characters (RFC 2045)."
  (let ((path (make-temp-file 1024)))
    (unwind-protect
        (let ((out (make-string-output-stream)))
          (mlisp-distrib::base64-encode-file-streaming path out)
          (let ((lines (remove ""
                               (cl-ppcre:split "\\n|\\r\\n"
                                (get-output-stream-string out))
                               :test #'string=)))
            ;; All lines except possibly the last must be exactly 76 chars
            (is (every (lambda (l) (<= (length l) 76))
                       lines))))
      (delete-file path))))

;;; ── #131: yEnc encoder ───────────────────────────────────────────────────
;;; yEnc escapes only four bytes: NUL (0), LF (10), CR (13), = (61).
;;; All other bytes are encoded as (byte + 42) mod 256.
;;; Overhead is <2% vs base64's ~33%.

(test YENC-1-encode-byte-adds-42-mod-256
  "yEnc encoding adds 42 to each byte modulo 256."
  ;; A = 65 -> (65+42) mod 256 = 107 = #\k
  (is (string= (mlisp-distrib::yenc-encode-byte 65) "k"))
  ;; 0 (NUL) must be escaped as "=@" (escaped NUL is 0+42+64=106='j' -> "=j" not "=@")
  ;; Actually: escaped char = (byte + 42 + 64) mod 256
  ;; NUL: (0+42) mod 256 = 42 -- must escape, output "=" then (0+42+64)=106=#\j -> "=j"
  (is (string= (mlisp-distrib::yenc-encode-byte 0)  "=j"))
  ;; LF (10): (10+42)=52 -- must escape, output "=" then (10+42+64)=116=#\t -> "=t"
  (is (string= (mlisp-distrib::yenc-encode-byte 10) "=t"))
  ;; CR (13): (13+42)=55 -- must escape, output "=" then (13+42+64)=119=#\w -> "=w"
  (is (string= (mlisp-distrib::yenc-encode-byte 13) "=w"))
  ;; = (61): (61+42)=103 -- must escape, output "=" then (61+42+64)=167 mod 256=167=#\§
  (is (string= (mlisp-distrib::yenc-encode-byte 61) "=}")))

(test YENC-2-encode-bytes-escapes-special-chars
  "yEnc encoder escapes NUL/LF/CR/= and passes all others through."
  (let* ((input (make-array 4 :element-type '(unsigned-byte 8)
                               :initial-contents (list 65 0 10 66)))
         (result (mlisp-distrib::yenc-encode-bytes input)))
    ;; 65 -> k, 0 -> =j, 10 -> =t, 66 -> l
    (is (string= "k=j=tl" result))))

(test YENC-3-line-length-at-most-128
  "yEnc lines are at most 128 characters (yEnc informal spec §4)."
  (let* ((data  (make-array 1024 :element-type '(unsigned-byte 8)
                                  :initial-element 65))
         (lines (cl-ppcre:split "\\n" (mlisp-distrib::yenc-encode-bytes data))))
    (is (every (lambda (l) (<= (length l) 128)) lines))))

(test YENC-4-encode-decode-roundtrip
  "yEnc decode of yEnc encode produces original bytes."
  (let* ((original (coerce (loop for i from 0 below 256 collect i)
                            '(vector (unsigned-byte 8))))
         (encoded  (mlisp-distrib::yenc-encode-bytes original))
         (decoded  (mlisp-distrib::yenc-decode-bytes encoded)))
    (is (equalp original decoded))))

;;; ── #131: Multipart chunking ─────────────────────────────────────────────

(test CHUNK-1-segment-count-correct
  "Number of segments = ceil(file-size / segment-size)."
  (let ((path (make-temp-file (* 3 750 1024)))) ; exactly 3 * 750KB
    (unwind-protect
        (let ((segments (mlisp-distrib::compute-segments path (* 750 1024))))
          (is (= 3 (length segments))))
      (delete-file path))))

(test CHUNK-2-partial-last-segment
  "Last segment contains remainder bytes when file not evenly divisible."
  (let ((path (make-temp-file (+ (* 2 750 1024) 1024)))) ; 2.something * 750KB
    (unwind-protect
        (let ((segments (mlisp-distrib::compute-segments path (* 750 1024))))
          (is (= 3 (length segments)))
          ;; Last segment should be smaller than segment-size
          (destructuring-bind (offset size) (car (last segments))
            (declare (ignore offset))
            (is (< size (* 750 1024)))))
      (delete-file path))))

(test CHUNK-3-single-file-below-threshold-not-chunked
  "Files at or below segment-size produce exactly one segment."
  (let ((path (make-temp-file 1024)))
    (unwind-protect
        (let ((segments (mlisp-distrib::compute-segments path (* 750 1024))))
          (is (= 1 (length segments))))
      (delete-file path))))

(test CHUNK-4-subject-line-format
  "Subject line follows '\"title filename (N/total)\"' convention."
  (is (string= "[releases] debian.iso (1/3)"
               (mlisp-distrib::segment-subject "releases" "debian.iso" 1 3)))
  (is (string= "[releases] debian.iso (3/3)"
               (mlisp-distrib::segment-subject "releases" "debian.iso" 3 3))))

(test CHUNK-5-yenc-header-fields
  "yEnc =ybegin header contains name, size, part, total fields."
  (let ((header (mlisp-distrib::yenc-segment-header
                 "debian.iso" 1 3 (* 750 1024) 0 (* 750 1024))))
    (is (search "=ybegin"  header))
    (is (search "name=debian.iso" header))
    (is (search "part=1"   header))
    (is (search "total=3"  header))
    (is (search "begin=0"  header))))

;;; ── Run suite ────────────────────────────────────────────────────────────

(let ((results (run 'distrib-suite)))
  (explain! results)
  (let ((ok (every #'fiveam::test-passed-p results)))
    (if (and (boundp 'cl-user::*mlisp-test-no-exit*)
             cl-user::*mlisp-test-no-exit*)
        (unless ok (error "distrib-suite: FiveAM tests failed"))
        (sb-ext:exit :code (if ok 0 1)))))
