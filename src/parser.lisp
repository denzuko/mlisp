;;;; src/parser.lisp — Minimal RFC 2822 header parser with CRLF tolerance

(in-package #:mlisp)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; RFC 2822 header parser (minimal, line-oriented)
;;; ─────────────────────────────────────────────────────────────────────────────

(defun parse-headers (lines)
  "Parse RFC 2822 header lines into an alist of (field . value) strings.
   Stops at first blank line (body separator)."
  (loop with headers = '()
        with current-field = nil
        with current-value = nil
        for line in lines
        do (cond
             ;; blank line = end of headers
             ((string= line "")
              (when current-field
                (push (cons current-field (string-trim '(#\Space #\Tab) current-value))
                      headers))
              (return (nreverse headers)))
             ;; continuation (folded header)
             ((member (char line 0) '(#\Space #\Tab))
              (when current-field
                (setf current-value (concatenate 'string current-value " "
                                                 (string-trim '(#\Space #\Tab) line)))))
             ;; new field
             (t
              (when current-field
                (push (cons current-field (string-trim '(#\Space #\Tab) current-value))
                      headers))
              (let ((colon (position #\: line)))
                (if colon
                    (setf current-field (string-upcase (subseq line 0 colon))
                          current-value (subseq line (1+ colon)))
                    (setf current-field nil current-value nil)))))
        finally
           (when current-field
             (push (cons current-field (string-trim '(#\Space #\Tab) current-value))
                   headers))
           (return (nreverse headers))))

(defun read-message-from-stdin ()
  "Read all lines from *standard-input*.
   Returns (values header-alist body-lines raw-lines).
   Strips trailing CR for CRLF tolerance."
  (flet ((strip-cr (s)
           (if (and (> (length s) 0) (char= (char s (1- (length s))) #\Return))
               (subseq s 0 (1- (length s)))
               s)))
    (let* ((all-lines (loop for line = (read-line *standard-input* nil nil)
                            while line collect (strip-cr line)))
           (sep-pos (position "" all-lines :test #'string=))
           (header-lines (if sep-pos (subseq all-lines 0 sep-pos) all-lines))
           (body-lines   (if sep-pos (subseq all-lines (1+ sep-pos)) '())))
      (values (parse-headers header-lines) body-lines all-lines))))

(defun header-value (headers field)
  "Return value of FIELD (case-insensitive) from HEADERS alist, or NIL."
  (cdr (assoc (string-upcase field) headers :test #'string=)))

(defun extract-address (str)
  "Extract bare email address from 'Display Name <addr>' or plain addr."
  (cond
    ((null str) nil)
    ((find #\< str)
     (let ((s (position #\< str))
           (e (position #\> str)))
       (when (and s e) (string-downcase (subseq str (1+ s) e)))))
    (t (string-downcase (string-trim '(#\Space #\Tab #\Newline) str)))))
