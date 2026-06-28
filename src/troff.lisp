;;;; src/troff.lisp — S-expression DSL → troff -ms → groff rendering

(in-package #:mlisp)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; troff/groff formatting subsystem
;;; ─────────────────────────────────────────────────────────────────────────────

;;; S-expression DSL for troff -ms macros
;;; Grammar:
;;;   (:document &rest block)
;;;   (:title "string") (:author "string") (:abstract "string")
;;;   (:p "string") (:pp "string")  — paragraph / first indented paragraph
;;;   (:b "string")                  — bold inline
;;;   (:section "heading")
;;;   (:quote "string")
;;;   (:raw "raw troff line")

(defun sexp->troff (form)
  "Compile a single DSL form to a troff -ms string."
  (ecase (car form)
    (:document
     (with-output-to-string (s)
       (format s ".ds CH~%.ds LH~%.ds RH~%")
       (dolist (block (cdr form))
         (write-string (sexp->troff block) s))))
    (:title
     (format nil ".TL~%~A~%.AU~%" (cadr form)))
    (:author
     (format nil "~A~%.AI~%" (cadr form)))
    (:abstract
     (format nil ".AB~%~A~%.AE~%" (cadr form)))
    (:section
     (format nil ".NH 1~%~A~%.LP~%" (cadr form)))
    (:p
     (format nil ".LP~%~A~%" (cadr form)))
    (:pp
     (format nil ".PP~%~A~%" (cadr form)))
    (:b
     (format nil "\\fB~A\\fP" (cadr form)))
    (:quote
     (format nil ".QS~%~A~%.QE~%" (cadr form)))
    (:raw
     (format nil "~A~%" (cadr form)))))

(defun render-troff-to-text (troff-source)
  "Pipe TROFF-SOURCE through groff -ms -Tutf8 -P-c; return rendered string."
  (let* ((proc (sb-ext:run-program "/usr/bin/groff"
                                   '("-ms" "-Tutf8" "-P-c")
                                   :input :stream
                                   :output :stream
                                   :error nil
                                   :wait nil))
         (in-s  (sb-ext:process-input proc))
         (out-s (sb-ext:process-output proc)))
    (write-string troff-source in-s)
    (close in-s)
    (let ((result (with-output-to-string (s)
                    (loop for c = (read-char out-s nil nil)
                          while c do (write-char c s)))))
      (sb-ext:process-wait proc)
      result)))

(defun load-template (list-id template-name)
  "Load templates/<list-id>.<template-name>.sexp and return the DSL form."
  (let ((path (merge-pathnames
               (format nil "~A.~A.sexp" list-id template-name)
               (template-dir))))
    (with-open-file (s path :direction :input :if-does-not-exist :error)
      (read s))))

(defun substitute-tokens (str bindings)
  "Replace {{key}} placeholders in STR with values from BINDINGS alist.
   BINDINGS is a list of (\"key\" . \"value\") string pairs.
   Unknown tokens are left in place."
  (let ((result str))
    (dolist (binding bindings result)
      (let* ((key     (car binding))
             (value   (cdr binding))
             (token   (format nil "{{~A}}" key)))
        (loop for pos = (search token result)
              while pos
              do (setf result (concatenate 'string
                                            (subseq result 0 pos)
                                            value
                                            (subseq result (+ pos (length token))))))))))

(defun substitute-sexp-tokens (form bindings)
  "Recursively substitute {{key}} tokens in string leaves of the DSL FORM."
  (cond
    ((null form) nil)
    ((stringp form) (substitute-tokens form bindings))
    ((listp form)   (mapcar (lambda (x) (substitute-sexp-tokens x bindings)) form))
    (t form)))

(defun render-template (list-id template-name &key extra-bindings)
  "Load templates/<list-id>.<template-name>.sexp, substitute tokens,
   compile to troff -ms, and render to plain text via groff.

   EXTRA-BINDINGS is an alist of (\"key\" . \"value\") pairs for
   {{key}} placeholder substitution in template string literals.

   Default bindings always available (from list state):
     {{list-address}}  — the list drop address
     {{list-name}}     — the list ID
     {{list-id}}       — synonym for {{list-name}}

   Operators add custom bindings via extra-bindings in call sites,
   or override defaults by including them in extra-bindings."
  (let* ((lst      (find-list list-id))
         (drop     (when lst (getf lst :drop-address)))
         (defaults (list (cons "list-address" (or drop list-id))
                         (cons "list-name"    list-id)
                         (cons "list-id"      list-id)))
         ;; extra-bindings override defaults
         (bindings (append extra-bindings defaults))
         (form     (load-template list-id template-name))
         (form     (substitute-sexp-tokens form bindings))
         (troff    (sexp->troff form)))
    (render-troff-to-text troff)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; MTA delivery
;;; ─────────────────────────────────────────────────────────────────────────────
