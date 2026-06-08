;;;; src/mime.lisp — Inbound MIME processing
;;;;
;;;; Extracts text/plain from multipart messages (prefers plain over HTML).
;;;; Strips HTML tags and decodes entities when only text/html is available.
;;;; Outbound distribution always uses the extracted plain text.
;;;;
;;;; Pure Common Lisp — no external dependencies.

(in-package #:mlisp)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; HTML entity table
;;; ─────────────────────────────────────────────────────────────────────────────

(defparameter *html-entities*
  '(("&amp;"   . "&")
    ("&lt;"    . "<")
    ("&gt;"    . ">")
    ("&quot;"  . "\"")
    ("&apos;"  . "'")
    ("&nbsp;"  . " ")
    ("&ndash;" . "-")
    ("&mdash;" . "--")
    ("&lsquo;" . "'")
    ("&rsquo;" . "'")
    ("&ldquo;" . "\"")
    ("&rdquo;" . "\"")
    ("&hellip;" . "...")
    ("&bull;"  . "*")
    ("&copy;"  . "(c)")
    ("&reg;"   . "(r)")
    ("&trade;" . "(tm)"))
  "Common HTML named entities and their plain text equivalents.")

;;; ─────────────────────────────────────────────────────────────────────────────
;;; HTML stripping
;;; ─────────────────────────────────────────────────────────────────────────────

(defun replace-one-entity (str entity replacement)
  "Replace all occurrences of ENTITY in STR with REPLACEMENT string."
  (with-output-to-string (out)
    (let ((pos 0)
          (elen (length entity)))
      (loop
        (let ((found (search entity str :start2 pos :test #'char-equal)))
          (if found
              (progn
                (write-string str out :start pos :end found)
                (write-string replacement out)
                (setf pos (+ found elen)))
              (progn
                (write-string str out :start pos)
                (return))))))))

(defun decode-numeric-entities (str)
  "Replace &#NNN; and &#xHHH; numeric character references in STR."
  (with-output-to-string (out)
    (let ((pos 0)
          (len (length str)))
      (loop while (< pos len) do
        (let ((amp (position #\& str :start pos)))
          (if (null amp)
              (progn (write-string str out :start pos) (return))
              (let ()
                (write-string str out :start pos :end amp)
                (let ((semi (position #\; str :start (+ amp 2))))
                  (if (and semi
                           (< semi (+ amp 10))
                           (< (1+ amp) len)
                           (char= (char str (1+ amp)) #\#))
                      (let* ((num-str (subseq str (+ amp 2) semi))
                             (code (handler-case
                                       (if (and (> (length num-str) 0)
                                                (char-equal (char num-str 0) #\x))
                                           (parse-integer num-str :start 1 :radix 16)
                                           (parse-integer num-str))
                                     (error () nil))))
                        (if (and code (< code 128) (> code 31))
                            (write-char (code-char code) out)
                            (write-string " " out))
                        (setf pos (1+ semi)))
                      (progn
                        (write-char #\& out)
                        (setf pos (1+ amp))))))))))))

(defun decode-html-entities (str)
  "Replace HTML named and numeric entities in STR with plain text equivalents."
  (let ((result str))
    (dolist (pair *html-entities*)
      (setf result (replace-one-entity result (car pair) (cdr pair))))
    (decode-numeric-entities result)))
(defun strip-html (str)
  "Remove all HTML tags from STR and decode entities.
   Inserts spaces/newlines at block element boundaries."
  (let ((result
         (with-output-to-string (out)
           (let ((pos 0)
                 (len (length str))
                 (in-tag nil))
             (loop while (< pos len) do
               (let ((c (char str pos)))
                 (cond
                   (in-tag
                    (when (char= c #\>)
                      (setf in-tag nil))
                    (incf pos))
                   ((char= c #\<)
                    ;; Emit newline before block elements
                    (let ((tag-start (1+ pos))
                          (tag-end (or (position #\> str :start (1+ pos)) len)))
                      (let ((tag (string-downcase
                                  (subseq str tag-start
                                          (min tag-end
                                               (+ tag-start
                                                  (min 10 (- tag-end tag-start))))))))
                        (when (or (search "p" tag :end2 (min 2 (length tag)))
                                  (search "br" tag)
                                  (search "div" tag)
                                  (search "tr" tag)
                                  (search "li" tag)
                                  (search "h" tag :end2 (min 2 (length tag))))
                          (write-char #\Newline out))))
                    (setf in-tag t)
                    (incf pos))
                   (t
                    (write-char c out)
                    (incf pos)))))))))
    ;; Collapse multiple blank lines, decode entities, trim trailing whitespace
    (let* ((decoded (decode-html-entities result))
           (lines (with-input-from-string (s decoded)
                    (loop for l = (read-line s nil nil)
                          while l collect (string-trim '(#\Space #\Tab) l)))))
      ;; Remove runs of more than 2 blank lines
      (string-right-trim
       '(#\Space #\Tab #\Newline #\Return)
       (with-output-to-string (out)
         (let ((blanks 0))
           (dolist (line lines)
             (if (string= line "")
                 (progn
                   (incf blanks)
                   (when (<= blanks 2)
                     (terpri out)))
                 (progn
                   (setf blanks 0)
                   (write-line line out))))))))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Content-Type classification
;;; ─────────────────────────────────────────────────────────────────────────────

(defun classify-content-type (ct)
  "Return a keyword classifying the Content-Type value CT."
  (when (null ct) (return-from classify-content-type :unknown))
  (let ((ct-lower (string-downcase ct)))
    (cond
      ((search "multipart/alternative" ct-lower) :multipart-alternative)
      ((search "multipart/mixed"       ct-lower) :multipart-mixed)
      ((search "multipart/"            ct-lower) :multipart-other)
      ((search "text/plain"            ct-lower) :text-plain)
      ((search "text/html"             ct-lower) :text-html)
      (t                                          :unknown))))

(defun extract-mime-boundary (ct)
  "Extract the boundary value from a multipart Content-Type header, or NIL."
  (when (null ct) (return-from extract-mime-boundary nil))
  (let* ((lower (string-downcase ct))
         (bpos  (search "boundary=" lower)))
    (when bpos
      (let* ((start (+ bpos 9))
             (raw   (subseq ct start)))
        ;; Remove surrounding quotes if present
        (if (and (> (length raw) 0) (char= (char raw 0) #\"))
            (let ((end (position #\" raw :start 1)))
              (if end (subseq raw 1 end) nil))
            ;; No quotes: boundary ends at whitespace or semicolon
            (let ((end (or (position-if (lambda (c)
                                          (member c '(#\; #\Space #\Tab #\Return #\Newline)))
                                        raw)
                           (length raw))))
              (subseq raw 0 end)))))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; MIME multipart splitter
;;; ─────────────────────────────────────────────────────────────────────────────

(defun split-mime-parts (body-lines boundary)
  "Split BODY-LINES by MIME BOUNDARY.
   Returns a list of (headers . body-lines) pairs for each part."
  (let ((delimiter      (concatenate 'string "--" boundary))
        (end-delimiter  (concatenate 'string "--" boundary "--"))
        (parts          '())
        (current-lines  '())
        (in-part        nil))
    (dolist (line body-lines)
      (cond
        ;; End delimiter — close last part
        ((string= line end-delimiter)
         (when in-part
           (push (nreverse current-lines) parts))
         (setf in-part nil current-lines '()))
        ;; Part delimiter — start new part
        ((string= line delimiter)
         (when in-part
           (push (nreverse current-lines) parts))
         (setf in-part t current-lines '()))
        ;; Inside a part
        (in-part
         (push line current-lines))))
    (when (and in-part current-lines)
      (push (nreverse current-lines) parts))
    ;; Parse part headers from each accumulated block
    (mapcar (lambda (part-lines)
              (let* ((sep  (position "" part-lines :test #'string=))
                     (hdrs (if sep
                               (parse-headers (subseq part-lines 0 sep))
                               '()))
                     (body (if sep
                               (subseq part-lines (1+ sep))
                               part-lines)))
                (cons hdrs body)))
            (nreverse parts))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Top-level MIME text extractor
;;; ─────────────────────────────────────────────────────────────────────────────

(defun mime-extract-text (raw-message)
  "Given RAW-MESSAGE as a string, return the best plain text body.
   Priority: text/plain part > stripped text/html > raw body."
  (let* ((lines      (with-input-from-string (s raw-message)
                       (loop for l = (read-line s nil nil) while l collect l)))
         (sep        (position "" lines :test #'string=))
         (hdrs       (parse-headers (if sep (subseq lines 0 sep) lines)))
         (body-lines (if sep (subseq lines (1+ sep)) '()))
         (ct         (header-value hdrs "Content-Type")))
    (case (classify-content-type ct)
      (:text-plain
       (format nil "~{~A~%~}" body-lines))
      (:text-html
       (strip-html (format nil "~{~A~%~}" body-lines)))
      ((:multipart-alternative :multipart-mixed :multipart-other)
       (let* ((boundary (extract-mime-boundary ct))
              (parts    (if boundary
                            (split-mime-parts body-lines boundary)
                            '())))
         ;; Prefer text/plain part; fall back to stripped text/html
         (let ((plain-part
                (find :text-plain parts
                      :key (lambda (p)
                             (classify-content-type
                              (header-value (car p) "Content-Type"))))))
           (if plain-part
               (format nil "~{~A~%~}" (cdr plain-part))
               (let ((html-part
                      (find :text-html parts
                            :key (lambda (p)
                                   (classify-content-type
                                    (header-value (car p) "Content-Type"))))))
                 (if html-part
                     (strip-html (format nil "~{~A~%~}" (cdr html-part)))
                     (format nil "~{~A~%~}" body-lines)))))))
      (otherwise
       (format nil "~{~A~%~}" body-lines)))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Integration hook for distribution pipeline
;;; ─────────────────────────────────────────────────────────────────────────────

(defun process-body-for-distribution (headers body-lines)
  "Return clean plain text body suitable for distribution.
   Strips MIME and HTML from inbound; outbound is always ASCII text."
  (let ((ct (header-value headers "Content-Type")))
    (case (classify-content-type ct)
      (:text-plain
       ;; Already plain — return as-is
       (format nil "~{~A~%~}" body-lines))
      ((:text-html :multipart-alternative :multipart-mixed :multipart-other)
       ;; Build a synthetic raw message for mime-extract-text
       (let ((synthetic
              (with-output-to-string (s)
                (dolist (h headers)
                  (format s "~A: ~A~%" (car h) (cdr h)))
                (terpri s)
                (dolist (line body-lines)
                  (write-line line s)))))
         (mime-extract-text synthetic)))
      (otherwise
       (format nil "~{~A~%~}" body-lines)))))
