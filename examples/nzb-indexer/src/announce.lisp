;;;; src/announce.lisp -- build announcement messages for completed releases

(in-package #:com.dwightaspencer.nzb-indexer)

(defun build-announce-body (idx title)
  "Build a plain-text announcement for a completed release.
   Sent to the -announce list when all segments have been indexed."
  (let ((release (find-release idx title)))
    (unless release
      (return-from build-announce-body nil))
    (let* ((segs     (sort (copy-list (release-segments release))
                           #'< :key #'segment-part))
           (total    (length segs))
           (filename (when segs (segment-filename (car segs))))
           (total-bytes (reduce #'+ segs :key #'segment-size :initial-value 0)))
      (with-output-to-string (s)
        (format s "New release available: ~A~%" title)
        (format s "~%")
        (format s "File:     ~A~%" filename)
        (format s "Segments: ~A~%" total)
        (format s "Size:     ~A bytes~%" total-bytes)
        (format s "~%")
        (format s "To retrieve the NZB index, send:~%")
        (format s "  Subject: get-nzb ~A~%" title)
        (format s "~%")
        (format s "Segment Message-IDs:~%")
        (dolist (seg segs)
          (format s "  [~A/~A] ~A~%"
                  (segment-part seg)
                  (segment-total seg)
                  (segment-message-id seg)))))))
