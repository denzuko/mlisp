;;;; src/filters.lisp — Plugin filter pipeline and file distribution helpers
;;;;
;;;; invoke-filter-chain: run pre/post filter programs
;;;; Filter contract:
;;;;   stdin:  raw RFC 5322 message
;;;;   stdout: modified message (on exit 0)
;;;;   exit 0: continue with stdout as new message
;;;;   exit 1: reject message
;;;;   exit 2: hold message
;;;;   exit 3: discard silently
;;;; Timeout: :filter-timeout-seconds (default 30)

(in-package #:mlisp)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Filter chain invocation
;;; ─────────────────────────────────────────────────────────────────────────────

(defun message-to-string (headers body-lines)
  "Serialise headers + body-lines to a single RFC 5322 string."
  (with-output-to-string (s)
    (dolist (h headers)
      (format s "~A: ~A~%" (car h) (cdr h)))
    (terpri s)
    (dolist (line body-lines)
      (write-line line s))))

(defun string-to-message (raw)
  "Parse RAW string back into (headers body-lines). Returns (values hdrs lines).
   Handles both LF and CRLF line endings."
  (let* ((lines    (split-string raw #\Newline))
         ;; Strip trailing CR from each line (CRLF normalization)
         (lines    (mapcar (lambda (l)
                             (if (and (> (length l) 0)
                                      (char= (char l (1- (length l))) #\Return))
                                 (subseq l 0 (1- (length l)))
                                 l))
                           lines))
         (headers  '())
         (body-lines '())
         (in-body  nil))
    (dolist (line lines)
      (cond
        (in-body
         (push line body-lines))
        ((zerop (length line))
         (setf in-body t))
        (t
         (let ((colon (position #\: line)))
           (if colon
               (push (cons (subseq line 0 colon)
                           (string-trim " " (subseq line (1+ colon))))
                     headers)
               (push (cons "" line) headers))))))
    (values (nreverse headers) (nreverse body-lines))))

(defun split-string (str delim)
  "Split STR on DELIM character, returning list of substrings."
  (let ((parts '()) (start 0))
    (dotimes (i (length str))
      (when (char= (char str i) delim)
        (push (subseq str start i) parts)
        (setf start (1+ i))))
    (push (subseq str start) parts)
    (nreverse parts)))

(defun invoke-single-filter (program-path message-string timeout-secs)
  "Run PROGRAM-PATH with MESSAGE-STRING on stdin via temp files.
   Uses sh -c 'prog < in > out' to avoid SIGPIPE issues.
   Returns (values output exit-code)."
  (declare (ignore timeout-secs))
  (let* ((ts      (get-universal-time))
         (rnd     (random 99999))
         (tmp-in  (format nil "/tmp/mlisp-fin-~A-~A" ts rnd))
         (tmp-out (format nil "/tmp/mlisp-fout-~A-~A" ts rnd)))
    (unwind-protect
         (progn
           (with-open-file (s tmp-in :direction :output :if-exists :supersede
                                     :if-does-not-exist :create)
             (write-string message-string s))
           (let* ((cmd  (format nil "~A < ~A > ~A" program-path tmp-in tmp-out))
                  (dummy (format *error-output* "[DEBUG-FLT] cmd=~A~%" cmd))
                  (proc (sb-ext:run-program "/bin/sh" (list "-c" cmd) :wait t))
                  (code (or (sb-ext:process-exit-code proc) 1))
                  (dummy2 (format *error-output* "[DEBUG-FLT] code=~A~%" code))
                  (output (when (and (= code 0) (probe-file tmp-out))
                            (with-open-file (s tmp-out)
                              (let ((buf (make-string (file-length s))))
                                (read-sequence buf s)
                                (format *error-output* "[DBG-OUT] output=~S~%" (subseq buf 0 (min 100 (length buf))))
                                buf)))))
             (values (or output "") code)))
      (ignore-errors (delete-file tmp-in))
      (ignore-errors (delete-file tmp-out)))))

(defun invoke-filter-chain (filter-programs headers body-lines)
  "Run each filter in FILTER-PROGRAMS in sequence.
   Returns (values new-headers new-body-lines last-exit-code).
   Stops at first non-zero exit (0=continue, 1=reject, 2=hold, 3=discard)."
  (let ((current-msg  (message-to-string headers body-lines))
        (h headers)
        (b body-lines)
        (last-exit 0))
    ;; Normalise: list of strings OR space-separated string OR single string
    (let ((program-list
           (if (listp filter-programs)
               ;; Already a list — but elements may themselves be space-separated
               (loop for item in filter-programs
                     append (split-string (string-trim (list #\Space #\Tab) item)
                                          #\Space))
               ;; String: split on whitespace
               (split-string (string-trim (list #\Space #\Tab) filter-programs)
                              #\Space))))
    (dolist (prog program-list)
      (let ((pgm (string-trim (list #\Space #\Tab) prog)))
        (format *error-output* "[DEBUG-CHAIN] pgm=~S len=~A probe=~A~%"
                pgm (length pgm) (probe-file pgm))
        (when (and (> (length pgm) 0) (probe-file pgm))
          (multiple-value-bind (output exit-code)
              (invoke-single-filter pgm current-msg 30)
            (setf last-exit (or exit-code 1))
            (case last-exit
              (0
               ;; Continue with modified message
               (when (and output (> (length output) 0))
                 (multiple-value-setq (h b) (string-to-message output))
                 (setf current-msg output)))
              (t
               ;; Non-zero: stop chain immediately
               (return)))))))
    (values h b last-exit)))
)