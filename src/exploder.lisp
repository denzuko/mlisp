;;;; src/exploder.lisp — List-of-lists (exploder) support
;;;;
;;;; An exploder list has :type :exploder and :member-lists (list of list IDs).
;;;; Posting to the exploder distributes to each member list independently,
;;;; with the member list's own RFC 2369 headers and loop guard.

(in-package #:mlisp)

(defun list-exploder-p (list-id)
  "Return T if list-id is an exploder type."
  (let ((lst (find-list list-id)))
    (when lst
      (let ((type (getf lst :type)))
        (or (eq type :exploder)
            (and (stringp type) (string-equal type "exploder")))))))

(defun exploder-members (list-id)
  "Return the member list IDs for exploder LIST-ID."
  (getf (find-list list-id) :member-lists))

(defun exploder-loop-header (exploder-id)
  "Return the X-Loop-Exploder-<id> header name."
  (format nil "X-Loop-Exploder-~:(~A~)" exploder-id))

(defun distribute-exploder (exploder-id from-addr headers body-lines)
  "Distribute a message to all member lists of EXPLODER-ID.
   Each member list gets its own full distribution with correct headers.
   Loop guard via X-Loop-Exploder-<id> header."
  (let ((loop-hdr (exploder-loop-header exploder-id))
        (members  (exploder-members exploder-id)))
    ;; Inject exploder loop guard before forwarding
    (let ((headers-with-guard (cons (cons loop-hdr "1") headers)))
      (dolist (member-id members)
        (when (find-list member-id)
          ;; Check member isn't also looping
          (unless (header-value headers (list-loop-header member-id))
            (distribute-message member-id from-addr
                                headers-with-guard body-lines)
            (audit-append (list :event :exploder-distributed
                                :source-list exploder-id
                                :target-list member-id
                                :from from-addr))
            (record-metric member-id :distributed)))))))
