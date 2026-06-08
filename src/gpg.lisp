;;;; src/gpg.lisp — Contact hashing at rest (SHA-256) and GPG support
;;;;
;;;; Hash contacts: when :hash-contacts t on a list, subscriber email
;;;; addresses are stored as SHA-256 hex digests in state.sexp.
;;;; Comparison uses the hash; plaintext is never written.
;;;;
;;;; GPG: when :require-signed t, unsigned posts are rejected with an
;;;; audit event. Signed messages are verified via gpg(1) shell-out.
;;;; No library dependencies — pure CL + system gpg binary.

(in-package #:mlisp)

;;; ─────────────────────────────────────────────────────────────────────────────
;;; SHA-256 implementation (pure CL, no FFI)
;;; ─────────────────────────────────────────────────────────────────────────────
;;; Based on FIPS 180-4. Operates on byte vectors.

;;; SHA-256 round constants (FIPS 180-4 §4.2.2)
;;; defparameter avoids defconstant non-EQL reload errors for array literals
(defparameter +sha256-k+
  #(#x428a2f98 #x71374491 #xb5c0fbcf #xe9b5dba5
    #x3956c25b #x59f111f1 #x923f82a4 #xab1c5ed5
    #xd807aa98 #x12835b01 #x243185be #x550c7dc3
    #x72be5d74 #x80deb1fe #x9bdc06a7 #xc19bf174
    #xe49b69c1 #xefbe4786 #x0fc19dc6 #x240ca1cc
    #x2de92c6f #x4a7484aa #x5cb0a9dc #x76f988da
    #x983e5152 #xa831c66d #xb00327c8 #xbf597fc7
    #xc6e00bf3 #xd5a79147 #x06ca6351 #x14292967
    #x27b70a85 #x2e1b2138 #x4d2c6dfc #x53380d13
    #x650a7354 #x766a0abb #x81c2c92e #x92722c85
    #xa2bfe8a1 #xa81a664b #xc24b8b70 #xc76c51a3
    #xd192e819 #xd6990624 #xf40e3585 #x106aa070
    #x19a4c116 #x1e376c08 #x2748774c #x34b0bcb5
    #x391c0cb3 #x4ed8aa4a #x5b9cca4f #x682e6ff3
    #x748f82ee #x78a5636f #x84c87814 #x8cc70208
    #x90befffa #xa4506ceb #xbef9a3f7 #xc67178f2))

(defun rotr32 (n x)
  (logand #xFFFFFFFF
          (logior (ash x (- n)) (ash x (- 32 n)))))

(defun sha256-bytes (data)
  "Compute SHA-256 of DATA (byte vector or string). Returns 32-byte vector."
  (let* ((bytes (if (stringp data)
                    (map '(vector (unsigned-byte 8)) #'char-code data)
                    data))
         (len   (length bytes))
         (bit-len (* len 8))
         ;; Pre-processing: pad to 512-bit blocks
         (pad-len (let ((r (mod (+ len 1 8) 64)))
                    (if (zerop r) 0 (- 64 r))))
         (total  (+ len 1 pad-len 8))
         (msg    (make-array total :element-type '(unsigned-byte 8) :initial-element 0)))
    ;; Copy data
    (replace msg bytes)
    ;; Append 1-bit
    (setf (aref msg len) #x80)
    ;; Append bit length as 64-bit big-endian
    (loop for i from 0 below 8 do
      (setf (aref msg (- total 1 i))
            (logand #xFF (ash bit-len (* i -8)))))
    ;; Initial hash values (first 32 bits of fractional parts of sqrt of primes)
    (let ((h (list #x6a09e667 #xbb67ae85 #x3c6ef372 #xa54ff53a
                   #x510e527f #x9b05688c #x1f83d9ab #x5be0cd19)))
      ;; Process each 512-bit block
      (loop for block-start from 0 below total by 64 do
        (let ((w (make-array 64 :initial-element 0)))
          ;; Prepare message schedule
          (loop for i from 0 below 16 do
            (setf (aref w i)
                  (logior (ash (aref msg (+ block-start (* i 4)))     24)
                          (ash (aref msg (+ block-start (* i 4) 1))   16)
                          (ash (aref msg (+ block-start (* i 4) 2))    8)
                          (aref msg (+ block-start (* i 4) 3)))))
          (loop for i from 16 below 64 do
            (let ((s0 (logxor (rotr32  7 (aref w (- i 15)))
                              (rotr32 18 (aref w (- i 15)))
                              (ash (aref w (- i 15)) -3)))
                  (s1 (logxor (rotr32 17 (aref w (- i  2)))
                              (rotr32 19 (aref w (- i  2)))
                              (ash (aref w (- i  2)) -10))))
              (setf (aref w i)
                    (logand #xFFFFFFFF
                            (+ (aref w (- i 16)) s0 (aref w (- i 7)) s1)))))
          ;; Compression
          (let ((a (first  h)) (b (second  h)) (c (third  h)) (d (fourth h))
                (e (fifth  h)) (f (sixth   h)) (g (seventh h)) (hh (eighth h)))
            (loop for i from 0 below 64 do
              (let* ((s1  (logxor (rotr32  6 e) (rotr32 11 e) (rotr32 25 e)))
                     (ch  (logxor (logand e f) (logand (lognot e) g)))
                     (tmp1 (logand #xFFFFFFFF
                                   (+ hh s1 ch (aref +sha256-k+ i) (aref w i))))
                     (s0  (logxor (rotr32  2 a) (rotr32 13 a) (rotr32 22 a)))
                     (maj  (logxor (logand a b) (logand a c) (logand b c)))
                     (tmp2 (logand #xFFFFFFFF (+ s0 maj))))
                (setf hh g g f f e
                      e (logand #xFFFFFFFF (+ d tmp1))
                      d c c b b a
                      a (logand #xFFFFFFFF (+ tmp1 tmp2)))))
            (setf h (list (logand #xFFFFFFFF (+ (first  h) a))
                          (logand #xFFFFFFFF (+ (second h) b))
                          (logand #xFFFFFFFF (+ (third  h) c))
                          (logand #xFFFFFFFF (+ (fourth h) d))
                          (logand #xFFFFFFFF (+ (fifth  h) e))
                          (logand #xFFFFFFFF (+ (sixth  h) f))
                          (logand #xFFFFFFFF (+ (seventh h) g))
                          (logand #xFFFFFFFF (+ (eighth h) hh)))))))
      ;; Produce 32-byte digest
      (let ((digest (make-array 32 :element-type '(unsigned-byte 8))))
        (loop for word in h for i from 0 do
          (loop for j from 0 below 4 do
            (setf (aref digest (+ (* i 4) j))
                  (logand #xFF (ash word (* (- 3 j) -8))))))
        digest))))

(defun sha256-hex (data)
  "Return lowercase hex string of SHA-256 digest of DATA (string or bytes)."
  (let ((digest (sha256-bytes data)))
    (with-output-to-string (s)
      (loop for b across digest do
        (format s "~(~2,'0x~)" b)))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; Hash-at-rest integration
;;; ─────────────────────────────────────────────────────────────────────────────

(defun list-hash-contacts-p (list-id)
  "Return T if the list has :hash-contacts t."
  (getf (find-list list-id) :hash-contacts))

(defun address-hash (address)
  "Return the SHA-256 hex hash of ADDRESS (lowercased)."
  (sha256-hex (string-downcase address)))

(defun subscriber-p-hashed (list-id address)
  "Check subscriber membership when hash-contacts is enabled.
   Compares SHA-256(address) against stored :address-hash fields."
  (let ((h (address-hash address)))
    (some (lambda (r)
            (string= (getf r :address-hash) h))
          (list-subscribers list-id))))

(defun add-subscriber-hashed (list-id address)
  "Add subscriber with hashed address when :hash-contacts t.
   Stores :address-hash only — no plaintext :address."
  (let ((h (address-hash address)))
    (unless (subscriber-p-hashed list-id address)
      (let ((lst (find-list list-id)))
        (when lst
          (setf (getf lst :subscribers)
                (cons (list :address-hash h
                            :subscribed-at (iso8601-now)
                            :consent-method "email-subscribe-command"
                            :bounce-count 0)
                      (getf lst :subscribers))))))))

(defun remove-subscriber-hashed (list-id address)
  "Remove subscriber by hash when :hash-contacts t."
  (let* ((h   (address-hash address))
         (lst (find-list list-id)))
    (when lst
      (setf (getf lst :subscribers)
            (remove h (getf lst :subscribers)
                    :key (lambda (r) (getf r :address-hash))
                    :test #'string=)))))

;;; ─────────────────────────────────────────────────────────────────────────────
;;; GPG message detection and verification
;;; ─────────────────────────────────────────────────────────────────────────────

(defun gpg-signed-p (headers body-lines)
  "Return T if the message appears to be PGP-signed."
  (let ((ct (string-downcase (or (header-value headers "Content-Type") ""))))
    (or (search "multipart/signed" ct)
        (search "pgp-signature" ct)
        ;; Inline signature in body
        (some (lambda (line)
                (search "-----BEGIN PGP SIGNED MESSAGE-----"
                        (string-upcase line)))
              body-lines))))

(defun gpg-encrypted-p (headers body-lines)
  "Return T if the message appears to be PGP-encrypted."
  (let ((ct (string-downcase (or (header-value headers "Content-Type") ""))))
    (or (search "multipart/encrypted" ct)
        (search "application/pgp-encrypted" ct)
        (some (lambda (line)
                (search "-----BEGIN PGP MESSAGE-----"
                        (string-upcase line)))
              body-lines))))

(defun list-require-signed-p (list-id)
  "Return T if list requires GPG-signed posts."
  (getf (find-list list-id) :require-signed))

(defun list-gpg-key-id (list-id)
  "Return the configured GPG key ID for the list, or nil."
  (getf (find-list list-id) :gpg-key-id))

(defun gpg-verify (message-string key-id)
  "Attempt to verify MESSAGE-STRING with gpg(1).
   Returns :verified, :failed, or :no-gpg."
  (declare (ignore key-id))
  (let ((gpg-bin (or (ignore-errors
                       (string-trim '(#\Space #\Newline)
                         (with-output-to-string (s)
                           (sb-ext:run-program "/usr/bin/which"
                             '("gpg") :output s :error nil :wait t))))
                     "/usr/bin/gpg")))
    (unless (probe-file gpg-bin)
      (return-from gpg-verify :no-gpg))
    (let* ((tmp (format nil "/tmp/mlisp-gpg-~A.msg" (get-universal-time))))
      (unwind-protect
           (progn
             (with-open-file (s tmp :direction :output
                                    :if-does-not-exist :create
                                    :if-exists :supersede)
               (write-string message-string s))
             (let ((proc (sb-ext:run-program
                          gpg-bin
                          (list "--batch" "--verify" tmp)
                          :output nil :error nil :wait t)))
               (if (zerop (sb-ext:process-exit-code proc))
                   :verified
                   :failed)))
        (ignore-errors (delete-file tmp))))))
