;;;; src/routing.lisp -- message routing and command detection

(in-package #:com.dwightaspencer.nzb-indexer)

(defun trim (s)
  (string-trim '(#\Space #\Tab #\Return #\Newline) (or s "")))

(defun x-loop-p (headers service-address)
  "Return T if X-Loop: matches SERVICE-ADDRESS (skip own replies)."
  (let ((val (cdr (assoc :x-loop headers))))
    (and val (string-equal (trim val) service-address))))

(defun distrib-message-p (headers)
  "Return T if this is a -distrib segment message (has (N/total) subject)."
  (let ((subj (cdr (assoc :subject headers))))
    (and subj
         (multiple-value-bind (fname part total)
             (parse-distrib-subject subj)
           (declare (ignore fname total))
           (not (null part))))))

(defun get-nzb-command-p (headers service-address)
  "Return T if this message is a get-nzb command to our service address."
  (let ((to   (cdr (assoc :to      headers)))
        (subj (cdr (assoc :subject headers))))
    (and to subj
         (or (string-equal (trim to) service-address)
             ;; tolerate 'Name <addr>' format
             (search service-address to))
         (let ((s (string-downcase (trim subj))))
           (or (string= "get-nzb" s :end2 (min 7 (length s)))
               (search "get-nzb" s))))))

(defun extract-nzb-title (headers)
  "Extract release title from a get-nzb command's Subject header."
  (let ((subj (trim (or (cdr (assoc :subject headers)) ""))))
    (let ((lower (string-downcase subj)))
      (let ((pos (search "get-nzb" lower)))
        (when pos
          (trim (subseq subj (+ pos 7))))))))
