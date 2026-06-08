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

(defun render-template (list-id template-name &key extra-bindings)
  "Load, optionally substitute EXTRA-BINDINGS, compile and render template."
  (declare (ignore extra-bindings))             ; future: token substitution
  (let* ((form   (load-template list-id template-name))
         (troff  (sexp->troff form)))
    (render-troff-to-text troff)))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; MTA delivery
;;; ─────────────────────────────────────────────────────────────────────────────
