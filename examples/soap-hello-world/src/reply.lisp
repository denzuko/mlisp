;;;; src/reply.lisp -- outbound SOAP email reply
;;;;
;;;; Per W3C SOAP 1.2 Email Binding §4.2.3 Table 9:
;;;;   From:         = request-uri (service address)
;;;;   To:           = sender-node-uri (caller) or list address
;;;;   In-Reply-To:  = correlation:requestMessageID
;;;;   Content-Type: = application/soap+xml (RFC 3902, REQUIRED)
;;;;   X-Loop:       = service address (loop guard)

(in-package #:com.dwightaspencer.soap-example)

(defun getenv (name &optional default)
  (or (sb-ext:posix-getenv name) default))

(defun sendmail-path ()
  (getenv "MLISP_SENDMAIL" "/usr/sbin/sendmail"))

(defun service-address ()
  (getenv "SOAP_SERVICE_ADDRESS" "soap-calc@example.com"))

(defun send-reply (to from subject in-reply-to soap-envelope-string mode)
  "Send the SOAP response email.
   MODE is :list or :direct (informational only; affects Precedence: header).
   X-Loop: is always set to FROM to guard against reprocessing."
  (let ((proc (sb-ext:run-program (sendmail-path) (list "-t")
                                   :input :stream :wait nil)))
    (let ((in (sb-ext:process-input proc)))
      (format in "From: ~A~%"           from)
      (format in "To: ~A~%"             to)
      (format in "Subject: Re: ~A~%"    subject)
      (when in-reply-to
        (format in "In-Reply-To: ~A~%"  in-reply-to)
        (format in "References: ~A~%"   in-reply-to))
      (format in "X-Loop: ~A~%"         from)
      (format in "MIME-Version: 1.0~%")
      (when (eq mode :list)
        (format in "Precedence: list~%"))
      ;; RFC 3902: application/soap+xml is REQUIRED
      (format in "Content-Type: ~A; charset=utf-8~%" +soap-media-type+)
      (format in "~%")
      (write-string soap-envelope-string in)
      (close in))
    (sb-ext:process-wait proc)))
