;;;; test/fiveam/test-nzb-indexer.lisp
;;;;
;;;; FiveAM BDD spec suite for com.dwightaspencer.nzb-indexer (#133).
;;;; Written BEFORE implementation per project BDD workflow.
;;;;
;;;; Run:
;;;;   (asdf:test-system :com.dwightaspencer.nzb-indexer)

;;; ── Bootstrap ────────────────────────────────────────────────────────────

(dolist (path (list
               (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))
               #p"/home/claude/quicklisp/setup.lisp"))
  (when (probe-file path) (load path) (return)))

(unless (find-package :fiveam)
  (funcall (find-symbol "QUICKLOAD" :ql) :fiveam :silent t))
(unless (find-package :cl-mime)
  (funcall (find-symbol "QUICKLOAD" :ql) :cl-mime :silent t))
(unless (find-package :xmls)
  (funcall (find-symbol "QUICKLOAD" :ql) :xmls :silent t))

(let* ((here (directory-namestring (truename *load-pathname*)))
       (root (namestring (truename (merge-pathnames "../../" (parse-namestring here))))))
  (unless (find-package :com.dwightaspencer.nzb-indexer)
    (pushnew (truename root) asdf:*central-registry* :test #'equal)
    (asdf:load-system :com.dwightaspencer.nzb-indexer/service)))

(defpackage #:nzb-indexer-tests
  (:use #:cl #:fiveam #:com.dwightaspencer.nzb-indexer))

(in-package #:nzb-indexer-tests)

(def-suite nzb-indexer-suite
  :description "NZB release indexer BDD specs (#133)")

(in-suite nzb-indexer-suite)

;;; ── Fixtures ─────────────────────────────────────────────────────────────

(defparameter *service-addr* "distrib-nzb@lists.example.com")
(defparameter *list-id*      "releases")

(defun make-distrib-msg (&key (from "releases@lists.example.com")
                               (to   "subscriber@example.com")
                               (message-id "<seg-001@example.com>")
                               (subject "[releases] debian.iso (1/3)")
                               (filename "debian.iso")
                               (part 1) (total 3)
                               (size 750000)
                               (offset 0))
  "Build a minimal distrib segment email as cl-mime would parse it."
  (format nil
    "From: ~A~%To: ~A~%Subject: ~A~%Message-ID: ~A~%~
     Content-Type: application/octet-stream~%~
     Content-Disposition: attachment; filename=~S~%~
     X-Yenc-Part: ~A~%X-Yenc-Total: ~A~%~
     X-Yenc-Size: ~A~%X-Yenc-Offset: ~A~%~
     MIME-Version: 1.0~%~%=ybegin part=~A total=~A name=~A~%~%"
    from to subject message-id filename part total size offset part total filename))

(defun make-get-nzb-msg (&key (from "user@example.com")
                               (to   "distrib-nzb@lists.example.com")
                               (title "debian.iso"))
  "Build a get-nzb command email."
  (format nil
    "From: ~A~%To: ~A~%Subject: get-nzb ~A~%Message-ID: <req-001@example.com>~%~
     Content-Type: text/plain~%MIME-Version: 1.0~%~%get-nzb ~A~%"
    from to title title))

;;; ── Subject parsing specs ────────────────────────────────────────────────

(test SUBJ-1-parse-distrib-subject
  "parse-distrib-subject extracts filename, part, total from [list] fname (N/total)."
  (multiple-value-bind (fname part total)
      (com.dwightaspencer.nzb-indexer:parse-distrib-subject
       "[releases] debian.iso (2/3)")
    (is (string= "debian.iso" fname))
    (is (= 2 part))
    (is (= 3 total))))

(test SUBJ-2-parse-single-message-subject
  "parse-distrib-subject returns nil for single-file subjects (no N/total)."
  (is (null (com.dwightaspencer.nzb-indexer:parse-distrib-subject
             "[releases] debian.iso"))))

(test SUBJ-3-parse-subject-various-filenames
  "parse-distrib-subject handles filenames with dots and hyphens."
  (multiple-value-bind (fname part total)
      (com.dwightaspencer.nzb-indexer:parse-distrib-subject
       "[releases] mlisp-0.8.0.tar.gz (1/2)")
    (is (string= "mlisp-0.8.0.tar.gz" fname))
    (is (= 1 part))
    (is (= 2 total))))

(test SUBJ-4-release-title-from-filename
  "release-title-from-filename strips extension for grouping."
  (is (string= "debian" (com.dwightaspencer.nzb-indexer:release-title-from-filename "debian.iso")))
  (is (string= "mlisp-0.8.0.tar" (com.dwightaspencer.nzb-indexer:release-title-from-filename "mlisp-0.8.0.tar.gz"))))

;;; ── Release index specs ──────────────────────────────────────────────────

(test IDX-1-add-segment-creates-release
  "add-segment creates a new release entry when none exists."
  (let ((idx (com.dwightaspencer.nzb-indexer:make-index)))
    (com.dwightaspencer.nzb-indexer:add-segment idx
      :title "debian" :filename "debian.iso"
      :message-id "<seg-001@example.com>"
      :part 1 :total 3 :size 750000 :offset 0)
    (is (com.dwightaspencer.nzb-indexer:find-release idx "debian"))))

(test IDX-2-add-segment-accumulates-parts
  "add-segment accumulates multiple segments under the same release."
  (let ((idx (com.dwightaspencer.nzb-indexer:make-index)))
    (com.dwightaspencer.nzb-indexer:add-segment idx
      :title "debian" :filename "debian.iso"
      :message-id "<seg-001@example.com>"
      :part 1 :total 3 :size 750000 :offset 0)
    (com.dwightaspencer.nzb-indexer:add-segment idx
      :title "debian" :filename "debian.iso"
      :message-id "<seg-002@example.com>"
      :part 2 :total 3 :size 750000 :offset 750000)
    (let ((release (com.dwightaspencer.nzb-indexer:find-release idx "debian")))
      (is (= 2 (com.dwightaspencer.nzb-indexer:release-segment-count release))))))

(test IDX-3-release-complete-when-all-parts-seen
  "release-complete-p returns T when all N segments have been indexed."
  (let ((idx (com.dwightaspencer.nzb-indexer:make-index)))
    (dotimes (i 3)
      (com.dwightaspencer.nzb-indexer:add-segment idx
        :title "debian" :filename "debian.iso"
        :message-id (format nil "<seg-~A@example.com>" (1+ i))
        :part (1+ i) :total 3
        :size 750000 :offset (* i 750000)))
    (let ((release (com.dwightaspencer.nzb-indexer:find-release idx "debian")))
      (is (com.dwightaspencer.nzb-indexer:release-complete-p release)))))

(test IDX-4-release-incomplete-when-parts-missing
  "release-complete-p returns NIL when fewer than total segments seen."
  (let ((idx (com.dwightaspencer.nzb-indexer:make-index)))
    (com.dwightaspencer.nzb-indexer:add-segment idx
      :title "debian" :filename "debian.iso"
      :message-id "<seg-001@example.com>"
      :part 1 :total 3 :size 750000 :offset 0)
    (let ((release (com.dwightaspencer.nzb-indexer:find-release idx "debian")))
      (is (not (com.dwightaspencer.nzb-indexer:release-complete-p release))))))

(test IDX-5-duplicate-segment-not-added-twice
  "add-segment is idempotent -- same Message-ID does not create duplicate."
  (let ((idx (com.dwightaspencer.nzb-indexer:make-index)))
    (dotimes (i 2)
      (com.dwightaspencer.nzb-indexer:add-segment idx
        :title "debian" :filename "debian.iso"
        :message-id "<seg-001@example.com>"
        :part 1 :total 3 :size 750000 :offset 0))
    (let ((release (com.dwightaspencer.nzb-indexer:find-release idx "debian")))
      (is (= 1 (com.dwightaspencer.nzb-indexer:release-segment-count release))))))

(test IDX-6-index-persistence-roundtrip
  "save-index / load-index roundtrip preserves all release data."
  (let* ((idx  (com.dwightaspencer.nzb-indexer:make-index))
         (path (merge-pathnames "nzb-test-index.sexp" (uiop:temporary-directory))))
    (unwind-protect
        (progn
          (com.dwightaspencer.nzb-indexer:add-segment idx
            :title "debian" :filename "debian.iso"
            :message-id "<seg-001@example.com>"
            :part 1 :total 1 :size 1024 :offset 0)
          (com.dwightaspencer.nzb-indexer:save-index idx path)
          (let* ((idx2    (com.dwightaspencer.nzb-indexer:load-index path))
                 (release (com.dwightaspencer.nzb-indexer:find-release idx2 "debian")))
            (is (not (null release)))
            (is (= 1 (com.dwightaspencer.nzb-indexer:release-segment-count release)))))
      (when (probe-file path) (delete-file path)))))

;;; ── NZB generation specs ─────────────────────────────────────────────────

(test NZB-1-build-nzb-produces-valid-xml
  "build-nzb returns a string containing valid XML."
  (let* ((idx (com.dwightaspencer.nzb-indexer:make-index)))
    (com.dwightaspencer.nzb-indexer:add-segment idx
      :title "debian" :filename "debian.iso"
      :message-id "<seg-001@example.com>"
      :part 1 :total 1 :size 1024 :offset 0)
    (let ((nzb (com.dwightaspencer.nzb-indexer:build-nzb idx "debian")))
      (is (search "<?xml" nzb))
      (is (search "<nzb" nzb)))))

(test NZB-2-nzb-contains-correct-namespace
  "NZB uses the official http://www.newzbin.com/DTD/2003/nzb namespace."
  (let* ((idx (com.dwightaspencer.nzb-indexer:make-index)))
    (com.dwightaspencer.nzb-indexer:add-segment idx
      :title "debian" :filename "debian.iso"
      :message-id "<seg-001@example.com>"
      :part 1 :total 1 :size 1024 :offset 0)
    (let ((nzb (com.dwightaspencer.nzb-indexer:build-nzb idx "debian")))
      (is (search "newzbin.com/DTD/2003/nzb" nzb)))))

(test NZB-3-nzb-contains-message-ids
  "NZB segment elements contain the correct Message-IDs."
  (let* ((idx (com.dwightaspencer.nzb-indexer:make-index)))
    (dotimes (i 3)
      (com.dwightaspencer.nzb-indexer:add-segment idx
        :title "debian" :filename "debian.iso"
        :message-id (format nil "<seg-~A@example.com>" (1+ i))
        :part (1+ i) :total 3
        :size 750000 :offset (* i 750000)))
    (let ((nzb (com.dwightaspencer.nzb-indexer:build-nzb idx "debian")))
      (is (search "seg-1@example.com" nzb))
      (is (search "seg-2@example.com" nzb))
      (is (search "seg-3@example.com" nzb)))))

(test NZB-4-nzb-nil-for-unknown-release
  "build-nzb returns nil for a release not in the index."
  (let ((idx (com.dwightaspencer.nzb-indexer:make-index)))
    (is (null (com.dwightaspencer.nzb-indexer:build-nzb idx "nonexistent")))))

(test NZB-5-nzb-segments-in-order
  "NZB segments appear in part-number order."
  (let* ((idx (com.dwightaspencer.nzb-indexer:make-index)))
    ;; Add out of order
    (com.dwightaspencer.nzb-indexer:add-segment idx
      :title "test" :filename "test.bin"
      :message-id "<seg-3@example.com>"
      :part 3 :total 3 :size 100 :offset 200)
    (com.dwightaspencer.nzb-indexer:add-segment idx
      :title "test" :filename "test.bin"
      :message-id "<seg-1@example.com>"
      :part 1 :total 3 :size 100 :offset 0)
    (com.dwightaspencer.nzb-indexer:add-segment idx
      :title "test" :filename "test.bin"
      :message-id "<seg-2@example.com>"
      :part 2 :total 3 :size 100 :offset 100)
    (let ((nzb (com.dwightaspencer.nzb-indexer:build-nzb idx "test")))
      (let ((pos1 (search "seg-1" nzb))
            (pos2 (search "seg-2" nzb))
            (pos3 (search "seg-3" nzb)))
        (is (< pos1 pos2))
        (is (< pos2 pos3))))))

;;; ── Command routing specs ────────────────────────────────────────────────

(test ROUTE-1-distrib-message-detected
  "distrib-message-p returns T for messages with (N/total) subject pattern."
  (let ((hdrs (mime:parse-headers
               (make-string-input-stream
                (format nil "Subject: [releases] debian.iso (1/3)~%~%")))))
    (is (com.dwightaspencer.nzb-indexer:distrib-message-p hdrs))))

(test ROUTE-2-non-distrib-message-not-detected
  "distrib-message-p returns NIL for plain list messages without (N/total)."
  (let ((hdrs (mime:parse-headers
               (make-string-input-stream
                (format nil "Subject: [releases] some announcement~%~%")))))
    (is (not (com.dwightaspencer.nzb-indexer:distrib-message-p hdrs)))))

(test ROUTE-3-get-nzb-command-detected
  "get-nzb-command-p returns T for messages addressed to the service with get-nzb subject."
  (let ((hdrs (mime:parse-headers
               (make-string-input-stream
                (format nil "To: distrib-nzb@lists.example.com~%Subject: get-nzb debian~%~%")))))
    (is (com.dwightaspencer.nzb-indexer:get-nzb-command-p hdrs *service-addr*))))

(test ROUTE-4-get-nzb-title-extracted
  "extract-nzb-title extracts release title from get-nzb command."
  (let ((hdrs (mime:parse-headers
               (make-string-input-stream
                (format nil "Subject: get-nzb debian-12-arm64~%~%")))))
    (is (string= "debian-12-arm64"
                 (com.dwightaspencer.nzb-indexer:extract-nzb-title hdrs)))))

(test ROUTE-5-x-loop-guard
  "Messages with X-Loop: matching service address are skipped."
  (let ((hdrs (mime:parse-headers
               (make-string-input-stream
                (format nil "X-Loop: distrib-nzb@lists.example.com~%~%")))))
    (is (com.dwightaspencer.nzb-indexer:x-loop-p hdrs *service-addr*))))

;;; ── Announce specs ───────────────────────────────────────────────────────

(test ANN-1-build-announce-body-contains-title
  "Announcement body includes the release title."
  (let* ((idx (com.dwightaspencer.nzb-indexer:make-index)))
    (com.dwightaspencer.nzb-indexer:add-segment idx
      :title "debian" :filename "debian.iso"
      :message-id "<seg-001@example.com>"
      :part 1 :total 1 :size 1024 :offset 0)
    (let ((body (com.dwightaspencer.nzb-indexer:build-announce-body idx "debian")))
      (is (search "debian" body)))))

(test ANN-2-build-announce-body-contains-segment-count
  "Announcement body reports total segment count."
  (let* ((idx (com.dwightaspencer.nzb-indexer:make-index)))
    (dotimes (i 3)
      (com.dwightaspencer.nzb-indexer:add-segment idx
        :title "debian" :filename "debian.iso"
        :message-id (format nil "<seg-~A@example.com>" (1+ i))
        :part (1+ i) :total 3
        :size 750000 :offset (* i 750000)))
    (let ((body (com.dwightaspencer.nzb-indexer:build-announce-body idx "debian")))
      (is (search "3" body)))))

;;; ── Run suite ────────────────────────────────────────────────────────────

(let ((results (run 'nzb-indexer-suite)))
  (explain! results)
  (let ((ok (every #'fiveam::test-passed-p results)))
    (if (and (boundp 'cl-user::*nzb-indexer-test-no-exit*)
             cl-user::*nzb-indexer-test-no-exit*)
        (unless ok (error "nzb-indexer-suite: FiveAM tests failed"))
        (sb-ext:exit :code (if ok 0 1)))))
