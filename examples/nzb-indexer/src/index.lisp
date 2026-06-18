;;;; src/index.lisp -- release index state
;;;;
;;;; A release is a named, ordered set of distrib segments that together
;;;; constitute a distributable file. The index maps release titles to
;;;; their segment metadata (Message-IDs, filenames, sizes, offsets).
;;;;
;;;; Storage: a single s-expression file ((:releases (...)) format),
;;;; read/written atomically via rename.

(in-package #:com.dwightaspencer.nzb-indexer)

;;; ── Data structures ──────────────────────────────────────────────────────

(defstruct segment
  "One segment of a release -- corresponds to one distrib message."
  message-id   ; string: RFC 5322 Message-ID header value
  filename     ; string: original filename
  part         ; integer: 1-indexed segment number
  total        ; integer: total segments in the release
  size         ; integer: segment size in bytes
  offset)      ; integer: byte offset within the original file

(defstruct release
  "A named set of segments constituting one distributable file."
  title        ; string: release title (derived from filename, sans ext)
  segments)    ; list of SEGMENT structs, may be incomplete

(defstruct index
  "The full release index: a hash table of title -> release."
  (releases (make-hash-table :test #'equal)))

;;; ── Subject parsing ──────────────────────────────────────────────────────

(defun parse-distrib-subject (subject)
  "Parse a distrib message subject of the form '[list-id] fname (N/total)'.
   Returns (values filename part total) or nil if no N/total found."
  (let ((str (string-trim '(#\Space #\Tab) subject)))
    ;; Strip leading [list-id] if present
    (when (char= (char str 0) #\[)
      (let ((close (position #\] str)))
        (when close
          (setf str (string-trim '(#\Space #\Tab)
                                  (subseq str (1+ close)))))))
    ;; Match "fname (N/total)" at end
    (let* ((open  (position #\( str :from-end t))
           (close (position #\) str :from-end t)))
      (when (and open close (> close open))
        (let ((inner (subseq str (1+ open) close)))
          (let ((slash (position #\/ inner)))
            (when slash
              (let ((n     (parse-integer (subseq inner 0 slash)     :junk-allowed t))
                    (total (parse-integer (subseq inner (1+ slash))  :junk-allowed t))
                    (fname (string-trim '(#\Space #\Tab)
                                        (subseq str 0 open))))
                (when (and n total (> n 0) (> total 0))
                  (values fname n total))))))))))

(defun release-title-from-filename (filename)
  "Derive a release title from FILENAME by stripping the last extension.
   'debian.iso' -> 'debian', 'mlisp-0.8.0.tar.gz' -> 'mlisp-0.8.0.tar'."
  (let ((dot (position #\. filename :from-end t)))
    (if dot (subseq filename 0 dot) filename)))

;;; ── Index operations ─────────────────────────────────────────────────────

(defun find-release (idx title)
  "Return the RELEASE struct for TITLE, or nil."
  (gethash title (index-releases idx)))

(defun add-segment (idx &key title filename message-id part total size offset)
  "Add a segment to the release index. Idempotent on Message-ID."
  (let* ((ht      (index-releases idx))
         (release (or (gethash title ht)
                      (setf (gethash title ht)
                            (make-release :title title :segments '())))))
    ;; Don't add duplicates (same Message-ID)
    (unless (find message-id (release-segments release)
                  :key #'segment-message-id :test #'string=)
      (push (make-segment :message-id message-id
                          :filename   filename
                          :part       part
                          :total      total
                          :size       size
                          :offset     offset)
            (release-segments release)))))

(defun release-segment-count (release)
  "Return the number of segments currently indexed for RELEASE."
  (length (release-segments release)))

(defun release-complete-p (release)
  "Return T if all expected segments have been indexed.
   Determined by comparing indexed count to the :total field of any segment."
  (let ((segs (release-segments release)))
    (and segs
         (let ((total (segment-total (car segs))))
           (= (length segs) total)))))

;;; ── Persistence ──────────────────────────────────────────────────────────

(defun index->sexp (idx)
  "Serialise index to a list of plists for writing to disk."
  (let ((releases '()))
    (maphash
     (lambda (title release)
       (push (list :title title
                   :segments
                   (mapcar (lambda (seg)
                             (list :message-id (segment-message-id seg)
                                   :filename   (segment-filename   seg)
                                   :part       (segment-part       seg)
                                   :total      (segment-total      seg)
                                   :size       (segment-size       seg)
                                   :offset     (segment-offset     seg)))
                           (release-segments release)))
             releases))
     (index-releases idx))
    (list :releases releases)))

(defun sexp->index (sexp)
  "Deserialise a sexp (from disk) back into an INDEX struct."
  (let ((idx (make-index)))
    (dolist (rdata (getf sexp :releases))
      (let ((title (getf rdata :title)))
        (dolist (sdata (getf rdata :segments))
          (add-segment idx
            :title      title
            :filename   (getf sdata :filename)
            :message-id (getf sdata :message-id)
            :part       (getf sdata :part)
            :total      (getf sdata :total)
            :size       (getf sdata :size)
            :offset     (getf sdata :offset)))))
    idx))

(defun save-index (idx path)
  "Write INDEX to PATH as an s-expression. Atomic: write to temp then rename."
  (let ((tmp (concatenate 'string (namestring path) ".tmp")))
    (with-open-file (s tmp :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create)
      (write (index->sexp idx) :stream s :readably t)
      (terpri s))
    (rename-file tmp path)))

(defun load-index (path)
  "Read and return an INDEX from PATH. Returns empty index if not found."
  (if (probe-file path)
      (with-open-file (s path)
        (sexp->index (read s)))
      (make-index)))
