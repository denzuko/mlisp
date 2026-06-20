;;;; src/filters.lisp — Plugin filter pipeline
;;;;
;;;; Filter contract (milter-compatible):
;;;;   stdin:  raw RFC 5322 message
;;;;   stdout: modified message (on exit 0)
;;;;   exit 0: continue with stdout as new message
;;;;   exit 1: reject message
;;;;   exit 2: hold message
;;;;   exit 3: discard silently

(in-package #:mlisp)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Macro: with-temp-io-files
;;; Shared temp-file lifecycle used by pipe-through-command and
;;; invoke-single-filter. Eliminates the ~40-line duplication between them.
;;; ─────────────────────────────────────────────────────────────────────────────

(defmacro with-temp-io-files ((in-var out-var input-string) &body body)
  "Bind IN-VAR and OUT-VAR to unique /tmp paths, write INPUT-STRING to the
   input file, execute BODY (which may reference both paths), then delete
   both files unconditionally via unwind-protect.

   BODY should return (values output-string-or-nil exit-code)."
  (let ((g-ts  (gensym "TS"))
        (g-rnd (gensym "RND"))
        (g-base (gensym "BASE")))
    `(let* ((,g-ts   (get-universal-time))
            (,g-rnd  (random 99999))
            (,g-base (format nil "~A-~A" ,g-ts ,g-rnd))
            (,in-var  (format nil "/tmp/mlisp-in-~A"  ,g-base))
            (,out-var (format nil "/tmp/mlisp-out-~A" ,g-base)))
       (unwind-protect
            (progn
              (with-open-file (s ,in-var :direction :output
                                         :if-exists :supersede
                                         :if-does-not-exist :create)
                (write-string ,input-string s))
              ,@body)
         (ignore-errors (delete-file ,in-var))
         (ignore-errors (delete-file ,out-var))))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Internal: run-shell-command — shared implementation
;;; ─────────────────────────────────────────────────────────────────────────────

(defun run-shell-command (command input-string)
  "Run COMMAND (a complete shell command string) with INPUT-STRING on stdin,
   using sh -c 'COMMAND < in > out' to avoid SIGPIPE. COMMAND is passed
   verbatim to sh, preserving all arguments and quoting.
   Returns (values output-string exit-code)."
  (with-temp-io-files (tmp-in tmp-out input-string)
    (let* ((cmd  (format nil "~A < ~A > ~A" command tmp-in tmp-out))
           (proc (sb-ext:run-program "/bin/sh" (list "-c" cmd) :wait t))
           (code (or (sb-ext:process-exit-code proc) 1))
           (output (when (and (= code 0) (probe-file tmp-out))
                     (with-open-file (s tmp-out)
                       (let ((buf (make-string (file-length s))))
                         (read-sequence buf s)
                         buf)))))
      (values (or output "") code))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Message serialisation / deserialisation
;;; ─────────────────────────────────────────────────────────────────────────────

(defun message-to-string (headers body-lines)
  "Serialise headers alist + body-lines list to a single RFC 5322 string."
  (with-output-to-string (s)
    (dolist (h headers)
      (format s "~A: ~A~%" (car h) (cdr h)))
    (terpri s)
    (dolist (line body-lines)
      (write-line line s))))

(defun split-string (str delim)
  "Split STR on DELIM character, returning list of substrings."
  (let ((parts '()) (start 0))
    (dotimes (i (length str))
      (when (char= (char str i) delim)
        (push (subseq str start i) parts)
        (setf start (1+ i))))
    (push (subseq str start) parts)
    (nreverse parts)))

(defun string-to-message (raw)
  "Parse RAW RFC 5322 string into (values headers body-lines).
   Delegates to parse-headers (src/parser.lisp) for header parsing,
   which handles folded headers and CRLF normalisation."
  (let* ((lines (split-string raw #\Newline))
         ;; Strip trailing CR (CRLF normalisation)
         (lines (mapcar (lambda (l)
                          (if (and (> (length l) 0)
                                   (char= (char l (1- (length l))) #\Return))
                              (subseq l 0 (1- (length l)))
                              l))
                        lines))
         (blank (position "" lines :test #'string=))
         (hdr-lines  (if blank (subseq lines 0 blank) lines))
         (body-lines (if blank (subseq lines (min (1+ blank) (length lines))) '())))
    (values (parse-headers hdr-lines) body-lines)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Public API
;;; ─────────────────────────────────────────────────────────────────────────────

(defun pipe-through-command (command input-string)
  "Run COMMAND (a shell command string) with INPUT-STRING on stdin.
   Returns (values output exit-code).

   For opt-in operator integrations such as:
     mlisp-admin bugs-report <pkg> --summarize <neural.sh invocation>
   INPUT-STRING is admin-tool-generated, not attacker-controlled email.
   See invoke-single-filter for the stricter untrusted-input contract."
  (run-shell-command command input-string))

(defun invoke-single-filter (program-path message-string timeout-secs)
  "Run PROGRAM-PATH as a complete shell command string with MESSAGE-STRING
   on stdin. PROGRAM-PATH is passed verbatim to sh -c, preserving arguments.
   Returns (values output exit-code)."
  (declare (ignore timeout-secs))
  (run-shell-command program-path message-string))

(defun all-tokens-executable-p (tokens)
  "Return T if every token in TOKENS is an existing, readable file path.
   Used to disambiguate a space-separated multi-filter string
   ('/path/f1 /path/f2') from a single command with arguments
   ('/path/neural.sh --model llama3')."
  (and tokens
       (every (lambda (tok) (and (> (length tok) 0) (probe-file tok)))
              tokens)))

(defun invoke-filter-chain (filter-programs headers body-lines)
  "Run each filter in FILTER-PROGRAMS in sequence against the message.
   Returns (values new-headers new-body-lines last-exit-code).
   Stops at first non-zero exit.

   FILTER-PROGRAMS may be:
     list    — each element is a separate shell command string, run in
               sequence. Preferred for multiple filters or any filter
               needing arguments: each element is passed verbatim to
               sh -c, so arguments and quoting are preserved.
     string  — if every whitespace-separated token is an existing file
               path, treated as a legacy space-separated list of filter
               paths (backward compatible with pre-existing configs that
               have no arguments). Otherwise treated as a single shell
               command string with arguments, passed verbatim to sh -c.

   Recommended for new configs: use the list form for multiple filters,
   and a single string (with arguments) for one filter:
     mlisp-admin set-option <list> pre-filter '/path/to/filter --arg val'"
  (let ((current-msg (message-to-string headers body-lines))
        (h headers)
        (b body-lines)
        (last-exit 0))
    (let ((program-list
           (cond
             ((null filter-programs) '())
             ((listp filter-programs)
              (remove-if (lambda (s)
                           (zerop (length (string-trim '(#\Space #\Tab) s))))
                         filter-programs))
             ((stringp filter-programs)
              (let* ((trimmed (string-trim '(#\Space #\Tab) filter-programs))
                     (tokens  (remove-if (lambda (s) (zerop (length s)))
                                        (split-string trimmed #\Space))))
                (cond
                  ((zerop (length trimmed)) '())
                  ;; Multiple tokens, all valid file paths: legacy
                  ;; space-separated multi-filter list (no arguments)
                  ((and (> (length tokens) 1) (all-tokens-executable-p tokens))
                   tokens)
                  ;; Otherwise: one command string, arguments preserved
                  (t (list trimmed)))))
             (t '()))))
      (dolist (pgm program-list)
        (let ((pgm (string-trim '(#\Space #\Tab) pgm)))
          (when (> (length pgm) 0)
            (multiple-value-bind (output exit-code)
                (invoke-single-filter pgm current-msg 30)
              (setf last-exit (or exit-code 1))
              (case last-exit
                (0
                 (when (and output (> (length output) 0))
                   (multiple-value-setq (h b) (string-to-message output))
                   (setf current-msg output)))
                (t (return))))))))
    (values h b last-exit)))
