;;;; src/distrib.lisp — File distribution engine for mlisp-distrib
;;;;
;;;; Distributes files as MIME attachments to -distrib list subscribers.
;;;; Suitable for binary release channels and filebone-style distribution.
;;;;
;;;; Encoding:
;;;;   - Files at or below :segment-size-kb (default 750KB per segment):
;;;;     single message, base64 (streaming, RFC 2045 76-char lines)
;;;;   - Files above :segment-size-kb: yEnc multipart segments posted as
;;;;     separate messages with subject "filename (N/total)" convention.
;;;;     yEnc overhead: <2% (vs base64 ~33%). Only escapes NUL/LF/CR/=.
;;;;
;;;; Fixes:
;;;;   #130 – base64-encode-file-streaming: never loads whole file into RAM
;;;;   #131 – yEnc multipart chunking: removes hard file-size ceiling

(defpackage #:mlisp-distrib
  (:use #:cl #:mlisp)
  (:export #:distrib-main
           ;; Exposed for test suite
           #:base64-encode-file
           #:base64-encode-file-streaming
           #:yenc-encode-byte
           #:yenc-encode-bytes
           #:yenc-decode-bytes
           #:compute-segments
           #:segment-subject
           #:yenc-segment-header))

(in-package #:mlisp-distrib)

;;; Forward declarations
(declaim (special mlisp:*mlisp-home-override*))
(declaim (ftype (function (t t) t) mlisp:audit-append mlisp:find-list))

;;; ── Utilities ────────────────────────────────────────────────────────────

(defun file-mime-type (filename)
  "Return a MIME type string based on file extension."
  (let* ((name (string-downcase filename))
         (dot  (position #\. name :from-end t))
         (ext  (if dot (subseq name (1+ dot)) "")))
    (cond
      ((member ext '("gz" "tgz" "bz2" "xz" "zip" "tar") :test #'string=)
       "application/octet-stream")
      ((string= ext "txt") "text/plain")
      ((string= ext "asc") "application/pgp-signature")
      (t "application/octet-stream"))))

(defun file-size (path)
  "Return file size in bytes, or nil."
  (ignore-errors
    (with-open-file (s path :element-type '(unsigned-byte 8))
      (file-length s))))

;;; ── #130: Streaming base64 encoder ──────────────────────────────────────
;;; base64-encode-file (legacy) reads the whole file into RAM -- kept for
;;; backward compatibility with distrib-get.
;;; base64-encode-file-streaming writes to a stream in 57-byte chunks,
;;; producing 76-char lines (RFC 2045). Never holds more than one chunk.

(defparameter +b64-chars+
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(defun base64-encode-file (path)
  "Return base64-encoded content of file at PATH, split into 76-char lines.
   NOTE: loads the whole file into RAM. Use base64-encode-file-streaming
   for large files (#130)."
  (with-output-to-string (out)
    (base64-encode-file-streaming path out)))

(defun base64-encode-file-streaming (path out-stream)
  "Write base64-encoded content of PATH to OUT-STREAM in 57-byte input
   chunks (= 76 base64 chars per line, RFC 2045). Never loads the whole
   file into memory -- safe for arbitrarily large files (#130)."
  (let ((buf (make-array 57 :element-type '(unsigned-byte 8))))
    (with-open-file (in path :element-type '(unsigned-byte 8))
      (loop
        (let ((n (read-sequence buf in)))
          (when (zerop n) (return))
          (base64-encode-chunk buf n out-stream)
          (terpri out-stream))))))

(defun base64-encode-chunk (buf n out-stream)
  "Encode N bytes from BUF as base64 to OUT-STREAM (no newline)."
  (loop for i from 0 below n by 3 do
    (let* ((b0 (aref buf i))
           (b1 (if (< (1+ i) n) (aref buf (1+ i)) 0))
           (b2 (if (< (+ i 2) n) (aref buf (+ i 2)) 0))
           (v  (logior (ash b0 16) (ash b1 8) b2)))
      (write-char (char +b64-chars+ (ldb (byte 6 18) v)) out-stream)
      (write-char (char +b64-chars+ (ldb (byte 6 12) v)) out-stream)
      (write-char (if (< (1+ i) n)
                      (char +b64-chars+ (ldb (byte 6 6) v))
                      #\=)
                  out-stream)
      (write-char (if (< (+ i 2) n)
                      (char +b64-chars+ (ldb (byte 6 0) v))
                      #\=)
                  out-stream))))

;;; ── #131: yEnc encoder/decoder ───────────────────────────────────────────
;;; yEnc informal spec (yenc.org): encode byte as (byte + 42) mod 256.
;;; Escape input bytes whose encoded form (byte+42)%256 would be a
;;; critical character: NUL(0) LF(10) CR(13) =(61).
;;; The input bytes that produce those encoded values are:
;;;   (0-42)%256=214 -> encodes to NUL -> escape to =@
;;;   (10-42)%256=224 -> encodes to LF  -> escape to =J
;;;   (13-42)%256=227 -> encodes to CR  -> escape to =M
;;;   (61-42)%256=19  -> encodes to =   -> escape to =}
;;; Line length: max 128 chars (yEnc spec §4).

(defparameter +yenc-offset+ 42)
(defparameter +yenc-escape-offset+ 64)
(defparameter +yenc-line-length+ 128)
;;; Input bytes whose encoded form (input+42)%256 is a special char.
;;; Do NOT escape the raw bytes 0/10/13/61 -- escape the inputs that PRODUCE those encoded values.
(defparameter +yenc-escape-bytes+ '(214 224 227 19))  ; produce NUL LF CR = after encoding

(defun yenc-encode-byte (byte)
  "Return yEnc encoding of BYTE as a string (1 or 2 chars).
   Input bytes 214/224/227/19 produce encoded values that are special
   (NUL/LF/CR/=) and must be escaped as '=' followed by (encoded+64)%256."
  (let ((encoded (mod (+ byte +yenc-offset+) 256)))
    (if (member byte +yenc-escape-bytes+)
        (let ((escaped (mod (+ encoded +yenc-escape-offset+) 256)))
          (format nil "=~C" (code-char escaped)))
        (format nil "~C" (code-char encoded)))))

(defun yenc-encode-bytes (bytes)
  "Return yEnc encoding of BYTES (vector of unsigned-byte 8) as a string,
   line-wrapped at +yenc-line-length+ characters."
  (with-output-to-string (out)
    (let ((col 0))
      (loop for byte across bytes do
        (let ((enc (yenc-encode-byte byte)))
          (when (> (+ col (length enc)) +yenc-line-length+)
            (terpri out)
            (setf col 0))
          (write-string enc out)
          (incf col (length enc))))
      (when (> col 0) (terpri out)))))

(defun yenc-decode-bytes (str)
  "Decode a yEnc-encoded STRING back to a byte vector."
  (let ((result (make-array (length str)
                             :element-type '(unsigned-byte 8)
                             :fill-pointer 0))
        (i 0)
        (len (length str)))
    (loop while (< i len) do
      (let ((c (char str i)))
        (cond
          ;; Skip line endings
          ((member c '(#\Newline #\Return)))
          ;; Escape sequence
          ((char= c #\=)
           (incf i)
           (when (< i len)
             (let* ((next   (char str i))
                    (decoded (mod (- (char-code next) +yenc-offset+
                                      +yenc-escape-offset+)
                                   256)))
               (vector-push decoded result))))
          ;; Regular byte
          (t
           (let ((decoded (mod (- (char-code c) +yenc-offset+) 256)))
             (vector-push decoded result))))
        (incf i)))
    (subseq result 0 (fill-pointer result))))

;;; ── #131: Segment computation ────────────────────────────────────────────

(defun compute-segments (path segment-size-bytes)
  "Return a list of (offset size) pairs for segmenting PATH.
   Each pair defines a byte range within the file."
  (let* ((total (or (file-size path) 0))
         (segments '()))
    (loop for offset from 0 below total by segment-size-bytes do
      (push (list offset (min segment-size-bytes (- total offset)))
            segments))
    (if segments
        (nreverse segments)
        (list (list 0 0)))))

(defun segment-subject (list-id fname part total)
  "Return the standard yEnc/NNTP subject for segment PART of TOTAL.
   Format: '[list-id] fname (part/total)'"
  (format nil "[~A] ~A (~A/~A)" list-id fname part total))

(defun yenc-segment-header (fname part total file-size offset segment-size)
  "Return a yEnc =ybegin header string for a file segment."
  (format nil "=ybegin part=~A total=~A line=~A size=~A name=~A~%~
               =ypart begin=~A end=~A~%"
          part total +yenc-line-length+ file-size fname
          (1+ offset)                          ; yEnc is 1-indexed
          (+ offset segment-size)))

(defun yenc-segment-footer (part size crc32)
  "Return a yEnc =yend footer string."
  (format nil "~%=yend size=~A part=~A pcrc32=~8,'0X~%"
          size part (or crc32 0)))

(defun read-file-segment (path offset size)
  "Read SIZE bytes from PATH starting at OFFSET. Returns a byte vector."
  (let ((buf (make-array size :element-type '(unsigned-byte 8))))
    (with-open-file (s path :element-type '(unsigned-byte 8))
      (file-position s offset)
      (let ((n (read-sequence buf s)))
        (subseq buf 0 n)))))

;;; ── distrib-file: single message or yEnc multipart ───────────────────────

(defun distrib-file (list-id file-path)
  "Send FILE-PATH to all subscribers of the distrib list LIST-ID.

   Files at or below :segment-size-kb (default 750KB): single message,
   base64 encoded (streaming, RFC 2045), no chunking.

   Files above :segment-size-kb: yEnc multipart -- each segment is
   posted as a separate message with subject 'fname (N/total)'."
  (unless (probe-file file-path)
    (format *error-output* "mlisp-distrib: file not found: ~A~%" file-path)
    (return-from distrib-file 1))
  (let* ((lst          (mlisp:find-list list-id))
         (seg-kb       (or (getf lst :segment-size-kb) 750))
         (seg-bytes    (* seg-kb 1024))
         (fname        (file-namestring file-path))
         (fsize        (or (file-size file-path) 0))
         (segments     (compute-segments file-path seg-bytes))
         (total        (length segments)))
    (if (= total 1)
        ;; ── Single message (base64, streaming) ───────────────────────────
        (distrib-file-single list-id file-path fname fsize lst)
        ;; ── Multipart yEnc segments ───────────────────────────────────────
        (progn
          (loop for (offset size) in segments
                for part from 1 do
            (distrib-file-segment list-id file-path fname fsize
                                   offset size part total lst))
          (mlisp:audit-append
           (list :event :distrib-sent :list list-id :file fname
                 :segments total))
          (format t "Distributed ~A (~A segment~:P) to ~A subscriber~:P on ~A~%"
                  fname total
                  (length (mlisp:subscriber-addresses list-id))
                  list-id)
          0))))

(defun distrib-file-single (list-id file-path fname fsize lst)
  "Send FILE-PATH as a single base64-encoded MIME message."
  (declare (ignore fsize lst))
  (let* ((drop     (mlisp:list-drop-address list-id))
         (req      (mlisp:list-request-address list-id))
         (mime-t   (file-mime-type fname))
         (b64      (with-output-to-string (s)
                     (base64-encode-file-streaming file-path s)))
         (boundary "mlisp-distrib-boundary-0001")
         (subj     (format nil "[~A] ~A" list-id fname))
         (body     (format nil
                     "--~A~%Content-Type: text/plain~%~%~
New file available: ~A~%List: ~A~%~
To request the index, send: get index~%~
--~A~%Content-Type: ~A~%~
Content-Transfer-Encoding: base64~%~
Content-Disposition: attachment; filename=~S~%~%~
~A~%--~A--~%"
                     boundary fname list-id
                     boundary mime-t fname b64 boundary))
         (extra-hdrs
          (append
           (mlisp:rfc2369-headers list-id)
           (list (cons "Subject"      subj)
                 (cons "Sender"       drop)
                 (cons "Reply-To"     req)
                 (cons "To"           drop)
                 (cons "MIME-Version" "1.0")
                 (cons "Content-Type"
                       (format nil "multipart/mixed; boundary=~S" boundary))
                 (cons (mlisp:list-loop-header list-id) "1"))))
         (addrs    (mlisp:subscriber-addresses list-id)))
    (dolist (addr addrs)
      (mlisp:sendmail (list addr) body :extra-headers extra-hdrs))
    (mlisp:audit-append
     (list :event :distrib-sent :list list-id :file fname))
    (format t "Distributed ~A to ~A subscriber~:P on ~A~%"
            fname (length addrs) list-id)
    0))

(defun distrib-file-segment (list-id file-path fname fsize
                              offset size part total lst)
  "Send one yEnc segment of FILE-PATH to all list subscribers."
  (declare (ignore lst))
  (let* ((drop     (mlisp:list-drop-address list-id))
         (req      (mlisp:list-request-address list-id))
         (raw      (read-file-segment file-path offset size))
         (header   (yenc-segment-header fname part total fsize offset size))
         (encoded  (yenc-encode-bytes raw))
         (footer   (yenc-segment-footer part size nil))
         (subj     (segment-subject list-id fname part total))
         (body     (concatenate 'string header encoded footer))
         (extra-hdrs
          (append
           (mlisp:rfc2369-headers list-id)
           (list (cons "Subject"               subj)
                 (cons "Sender"                drop)
                 (cons "Reply-To"              req)
                 (cons "To"                    drop)
                 (cons "MIME-Version"          "1.0")
                 (cons "Content-Type"          "application/octet-stream")
                 (cons "Content-Transfer-Encoding" "x-yenc")
                 (cons "Content-Disposition"
                       (format nil "attachment; filename=~S" fname))
                 (cons (mlisp:list-loop-header list-id) "1"))))
         (addrs    (mlisp:subscriber-addresses list-id)))
    (dolist (addr addrs)
      (mlisp:sendmail (list addr) body :extra-headers extra-hdrs))
    0))

;;; ── distrib-index ────────────────────────────────────────────────────────

(defun distrib-index (list-id)
  "Send the file index for LIST-ID to all subscribers."
  (let* ((lst   (mlisp:find-list list-id))
         (ddir  (getf lst :distrib-path))
         (drop  (mlisp:list-drop-address list-id))
         (addrs (mlisp:subscriber-addresses list-id)))
    (unless ddir
      (format *error-output* "mlisp-distrib: no distrib-path configured for ~A~%" list-id)
      (return-from distrib-index 1))
    (let* ((files (if (probe-file ddir)
                      (uiop:directory-files
                       (uiop:ensure-directory-pathname ddir))
                      '()))
           (body
            (with-output-to-string (s)
              (format s "[~A] Available files:~%~%" list-id)
              (if files
                  (dolist (f files)
                    (format s "  ~A  (~A bytes)~%"
                            (file-namestring f)
                            (ignore-errors
                              (with-open-file (fs f :element-type '(unsigned-byte 8))
                                (file-length fs)))))
                  (format s "  (no files available)~%"))
              (format s "~%To receive a file, send email to ~A~%~
with subject: get <filename>~%" drop)))
           (extra-hdrs
            (append
             (mlisp:rfc2369-headers list-id)
             (list (cons "Subject" (format nil "[~A] File index" list-id))
                   (cons "Sender" drop)
                   (cons "To"     drop)
                   (cons (mlisp:list-loop-header list-id) "1")))))
      (dolist (addr addrs)
        (mlisp:sendmail (list addr) body :extra-headers extra-hdrs))
      (format t "Sent index (~A file~:P) to ~A subscriber~:P on ~A~%"
              (length files) (length addrs) list-id)
      0)))

;;; ── distrib-get ──────────────────────────────────────────────────────────

(defun distrib-get (list-id filename requestor)
  "Send a specific file to REQUESTOR from the LIST-ID distrib spool."
  (let* ((lst  (mlisp:find-list list-id))
         (ddir (getf lst :distrib-path)))
    (unless ddir
      (format *error-output* "mlisp-distrib: no distrib-path for ~A~%" list-id)
      (return-from distrib-get 1))
    (let ((path (merge-pathnames filename (uiop:ensure-directory-pathname ddir))))
      (unless (probe-file path)
        (format *error-output* "mlisp-distrib: file not found: ~A~%" filename)
        (return-from distrib-get 1))
      (let ((extra-hdrs
             (append
              (mlisp:rfc2369-headers list-id)
              (list (cons "Subject"  (format nil "[~A] ~A" list-id filename))
                    (cons "To"       requestor)
                    (cons "Sender"   (mlisp:list-drop-address list-id))
                    (cons (mlisp:list-loop-header list-id) "1"))))
            (body (format nil "File: ~A~%~%~A" filename
                          (with-output-to-string (s)
                            (base64-encode-file-streaming path s)))))
        (mlisp:sendmail (list requestor) body :extra-headers extra-hdrs)
        (format t "Sent ~A to ~A~%" filename requestor)
        0))))

;;; ── distrib-main ─────────────────────────────────────────────────────────

(defun distrib-main ()
  "Entry point for mlisp-distrib binary.
   Usage: mlisp-distrib [--home <dir>] <list-id> <file>
          mlisp-distrib [--home <dir>] <list-id> --index"
  (let ((args (cdr sb-ext:*posix-argv*)))
    (when (or (null args) (member "--help" args :test #'string=))
      (format t
"Usage: mlisp-distrib [--home <dir>] <list-id> <file>
       mlisp-distrib [--home <dir>] <list-id> --index

Distribute a file or send the file index to all subscribers.

  <file>    Distribute file as MIME attachment to all subscribers.
            Files larger than :segment-size-kb (default 750KB) are
            split into yEnc segments with (N/total) subject lines.
  --index   Send current file index to all subscribers.

The list must be of type :distrib (mlisp-admin add-distrib).
")
      (sb-ext:exit :code (if (null args) 1 0)))

    (multiple-value-bind (home-dir _mode remaining)
        (mlisp::parse-common-flags args)
      (declare (ignore _mode))
      (when home-dir (setf mlisp:*mlisp-home-override* home-dir))

      (when (null remaining)
        (format *error-output* "mlisp-distrib: error: list-id required~%")
        (sb-ext:exit :code 1))

      (let ((list-id (string-downcase (first remaining)))
            (arg2    (second remaining)))
        (handler-case
            (progn
              (mlisp:load-state)
              (sb-ext:exit
               :code (cond
                 ((or (null arg2) (string= arg2 "--index"))
                  (distrib-index list-id))
                 (t
                  (distrib-file list-id arg2)))))
          (error (e)
            (format *error-output* "mlisp-distrib: fatal: ~A~%" e)
            (sb-ext:exit :code 2)))))))
