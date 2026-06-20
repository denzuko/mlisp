;;;; src/requests.lisp — Subscriber command handlers and archive access
;;;;
;;;; Covers: info, who, query, set-delivery, search (BITNET), index, get, files (AllFix)
;;;; All handlers send a reply via sendmail to the requesting address.

(in-package #:mlisp)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Helpers
;;; ─────────────────────────────────────────────────────────────────────────────

(defun cl-tokenize (str)
  "Split STR on whitespace, return list of non-empty tokens."
  (let ((tokens '()) (start nil))
    (dotimes (i (length str))
      (let ((c (char str i)))
        (cond
          ((member c '(#\Space #\Tab #\Return #\Newline))
           (when start
             (push (subseq str start i) tokens)
             (setf start nil)))
          (t
           (unless start (setf start i))))))
    (when start (push (subseq str start) tokens))
    (nreverse tokens)))

(defun extract-list-arg (body-lines)
  "Extract a list-id argument from body lines (e.g. 'who mlisp-discuss' → 'mlisp-discuss')."
  (let ((first (string-trim '(#\Space #\Tab #\Return #\Newline)
                             (or (first body-lines) ""))))
    (let ((tokens (cl-tokenize first)))
      ;; Look for a token that matches a known list in state
      (dolist (tok tokens)
        (when (and (> (length tok) 3) (find-list tok))
          (return tok))))))

(defun reply-to-sender (list-id from-addr subject body)
  "Send a reply email to FROM-ADDR with SUBJECT and BODY."
  (sendmail (list from-addr) body
            :extra-headers
            (list (cons "Subject" subject)
                  (cons "From"    (list-drop-address list-id))
                  (cons "To"      from-addr)
                  (cons "Precedence" "bulk"))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; #63: INFO command
;;; ─────────────────────────────────────────────────────────────────────────────

(defun handle-info-command (list-id from-addr body-lines)
  "Send list description and posting rules to FROM-ADDR."
  (let* ((target-id (or (extract-list-arg body-lines) list-id))
         (ns        (list-namespace target-id))
         (siblings  (when ns (namespace-siblings target-id)))
         (body
          (with-output-to-string (s)
            (format s "Mailing List Information~%")
            (format s "=======================~%~%")
            (dolist (sib (or siblings (list (find-list target-id))))
              (let ((id   (getf sib :id))
                    (desc (or (getf sib :description) "(no description)"))
                    (drop (list-drop-address (getf sib :id)))
                    (req  (list-request-address (getf sib :id))))
                (format s "List: ~A~%" id)
                (format s "  Description: ~A~%" desc)
                (format s "  Post to:     ~A~%" drop)
                (format s "  Commands:    ~A~%~%" req)))
            (format s "Commands: send to -request address~%")
            (format s "  subscribe      subscribe to default list~%")
            (format s "  subscribe X    subscribe to subgroup X~%")
            (format s "  unsubscribe    unsubscribe~%")
            (format s "  help           this message~%")
            (format s "  info           list information~%")
            (format s "  who            subscriber list (if advertised)~%")
            (format s "  query <list>   your delivery settings~%")
            (format s "  set <list> mail|nomail|digest   change delivery~%")
            (format s "  nomail         suspend delivery~%")
            (format s "  search <keyword> [in <list>]   search archive~%")
            (format s "  index <list>   list archived messages~%")
            (format s "  get <list> <N> retrieve archived message N~%"))))
    (reply-to-sender list-id from-addr
                     (format nil "Info: ~A" target-id)
                     body)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; #63: WHO command
;;; ─────────────────────────────────────────────────────────────────────────────

(defun handle-who-command (list-id from-addr body-lines)
  "Send subscriber list to FROM-ADDR if :advertised t."
  (let* ((target-id  (or (extract-list-arg body-lines) list-id))
         (lst        (find-list target-id))
         (advertised (when lst (getf lst :advertised)))
         (body
          (if advertised
              (let ((subs (subscriber-addresses target-id)))
                (with-output-to-string (s)
                  (format s "Subscribers of ~A (~A total):~%~%" target-id (length subs))
                  (dolist (addr subs)
                    (format s "  ~A~%" addr))))
              (format nil "The ~A list does not publish its membership.~%~%~
                            Contact the list owner if you need assistance.~%"
                      target-id))))
    (reply-to-sender list-id from-addr
                     (format nil "Who: ~A" target-id)
                     body)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; #63: QUERY command
;;; ─────────────────────────────────────────────────────────────────────────────

(defun handle-query-command (list-id from-addr body-lines)
  "Send FROM-ADDR their own delivery settings."
  (let* ((target-id (or (extract-list-arg body-lines) list-id))
         (sub       (find-subscriber target-id from-addr))
         (body
          (if sub
              (format nil
                "Your settings for ~A:~%~%~
                 Status:        subscribed~%~
                 Delivery:      ~A~%~
                 NOMAIL:        ~A~%~
                 Bounce count:  ~A~%~
                 Subscribed:    ~A~%~
                 Consent:       ~A~%"
                target-id
                (or (getf sub :delivery-mode) "individual")
                (if (getf sub :nomail) "suspended (send 'set mail' to resume)" "active")
                (or (getf sub :bounce-count) 0)
                (or (getf sub :subscribed-at) "unknown")
                (or (getf sub :consent-method) "unknown"))
              (format nil "You are not subscribed to ~A.~%~%~
                            To subscribe, send 'subscribe' to ~A~%"
                      target-id (list-request-address list-id)))))
    (reply-to-sender list-id from-addr
                     (format nil "Query: ~A" target-id)
                     body)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; #63: SET command — delivery mode self-service
;;; ─────────────────────────────────────────────────────────────────────────────

(defun handle-set-delivery-command (list-id from-addr body-lines)
  "Process 'set <list> mail|nomail|digest' from subscriber."
  (let* ((text    (string-downcase
                   (string-trim '(#\Space #\Tab #\Return #\Newline)
                                 (format nil "~{~A ~}" body-lines))))
         (tokens  (cl-tokenize text))
         (si      (position "set" tokens :test #'string=))
         ;; Find mode word (last non-list-id token after "set")
         (mode-str (when si
                     (let ((cands (cdr (nthcdr si tokens))))
                       (find-if (lambda (w)
                                  (member w '("mail" "nomail" "digest")
                                          :test #'string=))
                                cands))))
         (target-id (when si
                      (or (find-if #'find-list (cdr (nthcdr si tokens)))
                          list-id)))
         (mode (cond ((equal mode-str "nomail") :nomail)
                     ((equal mode-str "mail")   :mail)
                     ((equal mode-str "digest") :digest)
                     (t nil))))
    (if (and mode (find-subscriber (or target-id list-id) from-addr))
        (progn
          (case mode
            (:nomail (set-subscriber-nomail (or target-id list-id) from-addr t))
            (:mail
             (set-subscriber-nomail (or target-id list-id) from-addr nil)
             (let ((sub (find-subscriber (or target-id list-id) from-addr)))
               (when sub
                 (when (member :delivery-mode sub)
                   (setf (getf sub :delivery-mode) "individual"))
                 (save-state))))
            (:digest
             (let ((sub (find-subscriber (or target-id list-id) from-addr)))
               (when sub
                 (if (member :delivery-mode sub)
                     (setf (getf sub :delivery-mode) "digest")
                     (nconc sub (list :delivery-mode "digest")))
                 (save-state)))))
          (audit-append (list :event :set-delivery :list (or target-id list-id)
                              :from from-addr :mode mode))
          (reply-to-sender list-id from-addr
                           (format nil "Settings updated: ~A" (or target-id list-id))
                           (format nil "Your delivery mode for ~A has been set to ~A.~%"
                                   (or target-id list-id) mode-str)))
        (reply-to-sender list-id from-addr "Set delivery"
                         (format nil "Could not update settings. ~
                                       Valid modes: mail, nomail, digest.~%")))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Archive helpers
;;; ─────────────────────────────────────────────────────────────────────────────

(defun maildir-path (list-id)
  "Return path to Maildir new/ directory for LIST-ID.
   Under (maildir-root): $MAILDIR/lists/<list-id>/new/ if $MAILDIR is
   set, else $MLISP_HOME/state/maildir/<list-id>/new/."
  (merge-pathnames (format nil "~A/new/" list-id) (maildir-root)))

(defun maildir-messages (list-id)
  "Return sorted list of message file pathnames in the Maildir archive."
  (let ((dir (maildir-path list-id)))
    (when (probe-file dir)
      (sort (directory (merge-pathnames
                              (make-pathname :name :wild :type :wild) dir))
            #'string< :key #'namestring))))

(defun read-message-headers (path)
  "Read header lines from a message file at PATH and parse them via
   parse-headers (src/parser.lisp), the canonical RFC 5322 header parser
   (handles folded/continuation headers, case-insensitive field names).
   Returns alist with original-case field names matching the prior
   read-message-headers behavior (callers in bugs.lisp/requests.lisp use
   :test #'string-equal for lookups, so case is not significant to them,
   but the field name string itself is preserved as parse-headers
   upcases it -- callers already account for this)."
  (ignore-errors
    (with-open-file (s path)
      (let ((lines (loop for line = (read-line s nil nil)
                         while (and line (> (length line) 0))
                         collect line)))
        (parse-headers (append lines (list "")))))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; #64: SEARCH command (BITNET-style database search)
;;; ─────────────────────────────────────────────────────────────────────────────

(defun search-maildir (list-id keyword)
  "Search Maildir archive for KEYWORD. Returns formatted result string."
  (let* ((msgs     (maildir-messages list-id))
         (max      (or (getf (find-list list-id) :search-max-results) 20))
         (kw-lc    (string-downcase keyword))
         (results  '()))
    (dolist (path msgs)
      (when (>= (length results) max) (return))
      (let* ((hdrs    (read-message-headers path))
             (subj    (or (cdr (assoc "Subject" hdrs :test #'string-equal)) ""))
             (from    (or (cdr (assoc "From" hdrs :test #'string-equal)) ""))
             (date    (or (cdr (assoc "Date" hdrs :test #'string-equal)) ""))
             (body    (ignore-errors
                        (with-open-file (s path)
                          (let ((content (make-string 4096))
                                (n 0))
                            (setf n (read-sequence content s))
                            (subseq content 0 n))))))
        (when (or (search kw-lc (string-downcase subj))
                  (search kw-lc (string-downcase from))
                  (and body (search kw-lc (string-downcase body))))
          (push (list :subj subj :from from :date date
                      :n (1+ (length results)))
                results))))
    (if results
        (with-output-to-string (s)
          (format s "Search results for '~A' in ~A (~A match~:P):~%~%"
                  keyword list-id (length results))
          (dolist (r (nreverse results))
            (format s "~3D. ~A~%     From: ~A  Date: ~A~%~%"
                    (getf r :n) (getf r :subj)
                    (getf r :from) (getf r :date))))
        (format nil "No messages matching '~A' in ~A.~%" keyword list-id))))

(defun handle-search-command (list-id from-addr body-lines)
  (let* ((text    (format nil "~{~A ~}" body-lines))
         (tokens  (cl-tokenize text))
         (si      (position "search" tokens :test #'string-equal))
         (keyword (when si (nth (1+ si) tokens)))
         (target  (or (find-if #'find-list (when si (cddr (nthcdr si tokens))))
                      (extract-list-arg body-lines)
                      list-id))
         (lst     (find-list target))
         (enabled (when lst (getf lst :search-enabled)))
         (result
          (cond
            ((not keyword)
             "Usage: search <keyword> [in <list-id>]")
            ((not enabled)
             (format nil "Archive search is not enabled for ~A.~%~
                           Ask the list owner to enable it with:~%~
                           mlisp-admin set-option ~A search-enabled true~%" target target))
            (t (search-maildir target keyword)))))
    (reply-to-sender list-id from-addr
                     (format nil "Search: ~A" (or keyword ""))
                     result)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; #64: INDEX command
;;; ─────────────────────────────────────────────────────────────────────────────

(defun index-maildir (list-id)
  "Return formatted index of Maildir archive messages."
  (let ((msgs (maildir-messages list-id)))
    (if msgs
        (with-output-to-string (s)
          (format s "Archive index for ~A (~A message~:P):~%~%" list-id (length msgs))
          (loop for path in msgs
                for n from 1
                do (let* ((hdrs (read-message-headers path))
                           (subj (or (cdr (assoc "Subject" hdrs :test #'string-equal)) "(no subject)"))
                           (from (or (cdr (assoc "From" hdrs :test #'string-equal)) ""))
                           (date (or (cdr (assoc "Date" hdrs :test #'string-equal)) "")))
                     (format s "~4D. ~A~%      ~A  ~A~%~%" n subj from date))))
        (format nil "No archived messages for ~A.~%~
                      Use 'set-option ~A search-enabled true' to enable archiving.~%"
                list-id list-id))))

(defun handle-index-command (list-id from-addr body-lines)
  (let* ((target (or (extract-list-arg body-lines) list-id))
         (result (index-maildir target)))
    (reply-to-sender list-id from-addr
                     (format nil "Index: ~A" target)
                     result)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; #64: GET command — retrieve archived message
;;; ─────────────────────────────────────────────────────────────────────────────

(defun get-archived-message (list-id n)
  "Return the Nth archived message as a string, or nil."
  (let ((msgs (maildir-messages list-id)))
    (when (and msgs (<= 1 n (length msgs)))
      (ignore-errors
        (with-open-file (s (nth (1- n) msgs))
          (let ((buf (make-string (* 256 1024))))
            (let ((len (read-sequence buf s)))
              (subseq buf 0 len))))))))

(defun handle-get-archive-command (list-id from-addr body-lines)
  (let* ((text   (format nil "~{~A ~}" body-lines))
         (tokens (cl-tokenize text))
         (gi     (position "get" tokens :test #'string-equal))
         (target (when gi
                   (or (find-if #'find-list (cdr (nthcdr gi tokens)))
                       list-id)))
         (num    (when gi
                   (or (find-if (lambda (tok)
                                  (and tok (parse-integer tok :junk-allowed t)
                                       (> (or (parse-integer tok :junk-allowed t) 0) 0)))
                                (cdr (nthcdr gi tokens)))
                       "0")))
         (num-val (if (stringp num)
                      (or (parse-integer num :junk-allowed t) 0)
                      (or num 0)))
         (msg    (when (> num-val 0) (get-archived-message (or target list-id) num-val))))
    (if msg
        (reply-to-sender list-id from-addr
                         (format nil "Message ~A from ~A archive" num-val (or target list-id))
                         msg)
        (reply-to-sender list-id from-addr "Archive retrieval"
                         (format nil "Message ~A not found in ~A archive.~%~
                                       Use 'index ~A' to see available messages.~%"
                                 num-val (or target list-id) (or target list-id))))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; #65: FILES command — AllFix-style file area listing
;;; ─────────────────────────────────────────────────────────────────────────────
(defun handle-file-index-command (list-id from-addr body-lines)
  (let* ((target (or (extract-list-arg body-lines)
                     ;; Auto-find -distrib sibling
                     (let ((ns (list-namespace list-id)))
                       (when ns
                         (let ((distrib-id (format nil "~A-distrib" ns)))
                           (when (find-list distrib-id) distrib-id))))
                     list-id))
         (result (list-distrib-files target)))
    (reply-to-sender list-id from-addr
                     (format nil "Files: ~A" target)
                     result)))

