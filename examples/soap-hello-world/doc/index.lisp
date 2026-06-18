;;;; doc/index.lisp -- 40ants-doc documentation for com.dwightaspencer.soap-example
;;;;
;;;; Part of com.dwightaspencer.soap-example/doc (soap-service.asd).
;;;; Kept in a separate system so the transport/service systems stay
;;;; free of the 40ants-doc-full dependency tree.

(uiop:define-package #:com.dwightaspencer.soap-example/doc
  (:use #:cl)
  (:export #:@index)
  (:import-from #:40ants-doc #:defsection))

(in-package #:com.dwightaspencer.soap-example/doc)


(defsection @index
    (:title "com.dwightaspencer.soap-example"
     :ignore-words ("AM" "API" "ASDF" "BDD" "CLI" "DKIM" "DMARC" "DNS"
                     "DNSSEC" "GPG" "HTTP" "IMAP" "MDA" "MIME" "MTA"
                     "MTA-STS" "NZB" "PAR2" "POSIX" "RFC" "S-MIME" "SBCL"
                     "SMTP" "SOAP" "SPF" "SSL" "TLS" "W3C" "XML"
                     "XSD" "mTLS" "mlisp" "procmail" "fetchmail"
                     "Quicklisp" "Ultralisp" "Roswell" "qlot"
                     "Maildir" "NNTP" "WSDL" "ARC"))
  "W3C SOAP 1.2 Email Binding microservice example.

   Email is the only transport layer. No HTTP, no external endpoints.
   A SOAP 1.2 envelope is the payload in both directions, carried
   inside standard RFC 5322 internet messages with
   `application/soap+xml` (RFC 3902) as the Content-Type.

   The codebase is split into four systems sharing one package
   (`com.dwightaspencer.soap-example`, nickname `soap-example`):

   - `com.dwightaspencer.soap-example/soap12-email` -- the generic
     transport library (routing, SOAP parsing/building, Maildir batch
     processing, email security header inspection).
   - `com.dwightaspencer.soap-example/service` -- a calculator
     microservice example built on top of the transport layer.
   - `com.dwightaspencer.soap-example/tests` -- 61-spec FiveAM BDD
     suite covering all layers.
   - `com.dwightaspencer.soap-example/doc` -- this documentation."

  (@transport section)
  (@security section)
  (@service section)
  (@routing section)
  (@todo section))


(defsection @transport
    (:title "Transport layer (soap12-email)"
     :ignore-words ("RFC" "SOAP" "MIME" "MTA" "MDA" "Maildir" "W3C"
                     "DKIM" "SPF" "DMARC" "mlisp" "fetchmail" "qlot"))
  "The `soap12-email` system implements the W3C SOAP Version 1.2
   Email Binding (W3C Note, 3 July 2002) as a batch Maildir processor.

   **Specs implemented:**

   - W3C SOAP 1.2 Email Binding -- transport binding framework
   - RFC 3902 -- `application/soap+xml` media type (required by W3C spec)
   - RFC 2045 -- MIME packaging (via `cl-mime`)
   - RFC 5322 -- internet message format (via `cl-mime`)
   - RFC 2369 / RFC 2919 -- mailing list headers (`List-Post:`, `List-Id:`)
   - RFC 7601 -- `Authentication-Results` header (email security)

   **Architecture:**

   ```
   cron (every 5 minutes)
     fetchmail -> $MAILDIR/new/        ; pull from IMAP/POP3
     soap-example binary (batch)
       for each file in new/:
         skip if X-Loop: matches service address (loop guard)
         skip if Content-Type is not application/soap+xml
         inspect security headers (DKIM, SPF, DMARC)
         parse SOAP 1.2 envelope (xmls, in-process)
         dispatch operation via injected handler
         discover reply address (list vs direct, RFC 2369/2919)
         sendmail reply:
           Content-Type: application/soap+xml (RFC 3902)
           In-Reply-To: <request Message-ID>  (W3C correlation)
           X-Loop: <service address>           (loop guard)
         mv new/msg -> cur/msg                (Maildir mark-read)
   ```

   **Key functions:**

   - `process-batch` -- main batch loop; accepts injected `:handler`
     and `:envelope-builder` for service-specific dispatch.
   - `parse-soap-envelope` -- parses message body as SOAP 1.2 envelope.
   - `build-soap-envelope` -- builds a SOAP 1.2 envelope; accepts
     `:extra-namespaces` for caller-supplied namespace declarations.
   - `send-reply` -- sends reply per W3C spec (Table 9).")


(defsection @security
    (:title "Email security"
     :ignore-words ("AM" "DKIM" "SPF" "DMARC" "DNSSEC" "MTA" "MDA" "MTA-STS"
                     "mTLS" "SSL" "TLS" "GPG" "ARC" "RFC" "MIME" "S-MIME"
                     "procmail" "fetchmail" "mlisp" "Postfix"))
  "**Layered security model**

   The application layer does not re-implement email security
   primitives -- it trusts and surfaces the verdicts recorded by the
   MTA/MDA stack (Postfix + DKIM milter + SPF policy daemon + DMARC
   reporter + fetchmail + procmail) before messages reach `$MAILDIR/`.

   **What the MTA/MDA stack handles (outside this library):**

   - DNSSEC -- recursive resolver enforces DNSSEC validation on SPF/
     DKIM/DMARC/MTA-STS DNS lookups.
   - MTA-STS -- Postfix enforces SMTP-over-TLS policy before accepting
     inbound mail (RFC 8461).
   - DKIM -- milter (e.g. OpenDKIM) verifies and signs; result recorded
     in `Authentication-Results:`.
   - SPF -- Postfix policy daemon checks sender; result in
     `Authentication-Results:` and/or `Received-SPF:`.
   - DMARC -- daemon checks alignment of DKIM/SPF; result in
     `Authentication-Results:`.
   - mTLS -- TLS client certificate verification for SMTP sessions (MTA
     configuration; no application-layer code required).
   - GPG/S-MIME content signing -- deliberately out of scope; handle at
     the MDA layer (procmail + gpg) before delivery to `$MAILDIR/` if
     required.

   **What this library provides (application layer):**

   The `Authentication-Results:` (RFC 7601) header is parsed and
   surfaced for routing decisions and audit logging:

   - `authentication-results-p` -- header present?
   - `check-authentication-results` -- parse to alist.
   - `dkim-pass-p` -- DKIM verified?
   - `spf-pass-p` -- SPF passed? (checks both `Authentication-Results:`
     and `Received-SPF:`)
   - `dmarc-pass-p` -- DMARC policy passed?

   **Deployment note:** a correctly configured Postfix + mlisp stack
   already enforces SPF/DKIM/DMARC at the MTA layer. Messages that
   fail authentication are typically rejected or quarantined before
   they reach `$MAILDIR/`. The application-layer checks here provide
   defence-in-depth for audit logging and for deployments where the
   MTA stack records but does not enforce verdicts.")


(defsection @service
    (:title "Service layer (calculator example)"
     :ignore-words ("SOAP" "MTA" "RFC"))
  "The `service` system provides a worked example of how to build a
   SOAP 1.2 Email Binding service on top of the transport library.

   **Handler protocol:**

   ```lisp
   (lambda (operation)
     ;; operation -- xmls node (first child of soap:Body)
     ;; returns   -- (values body-content-string fault-p)
     ...)
   ```

   Wire your handler to the transport via `process-batch`:

   ```lisp
   (process-batch maildir service-address
                  :handler          #'my-handler
                  :envelope-builder #'my-envelope-builder)
   ```

   The calculator example (`dispatch-soap`, `calc-envelope`,
   `*calc-ns*`, `*calc-prefix*`) implements the handler protocol for
   the namespace `http://example.com/soap/calculator/` with operations
   `Add`, `Subtract`, `Multiply`, and `Divide`. Replace
   `src/dispatch.lisp` entirely for a different service.")


(defsection @routing
    (:title "Reply address discovery"
     :ignore-words ("RFC" "SOAP" "W3C" "DKIM" "SPF" "DMARC"))
  "Per W3C SOAP 1.2 Email Binding section 4.2.3 (Table 9), the
   response `To:` field is the `sender-node-uri` from the request.

   When the request arrived via a mailing list (RFC 2369/2919 headers),
   the list address is the transport endpoint and all subscribers --
   including downstream SOAP consumers -- should receive the response.

   `reply-to-address` discovers the correct address automatically:

   | Inbound headers | Mode | To: in reply |
   |---|---|---|
   | `List-Id:`, `List-Post:`, `Mailing-List:`, or `Precedence: list` | `:list` | `List-Post:` address (or `To:` fallback) |
   | None | `:direct` | `From:` address |

   `X-Loop:` is set on all outbound replies to the service address.
   Inbound messages with a matching `X-Loop:` are skipped without
   reply, preventing reprocessing of the service's own list replies
   when fetchmail delivers them back into `$MAILDIR/new/`.")


(defsection @todo
    (:title "Next steps"
     :ignore-words ("SOAP" "RFC" "NZB" "PAR2" "NNTP" "CLI" "mlisp"
                     "JSON" "RPC" "WSDL" "GPG" "Quicklisp" "Ultralisp"))
  "- Publish `com.dwightaspencer.soap-example/soap12-email` as a
    standalone library (rename, 40ants-doc pages, Ultralisp submission).
  - Usenet/distrib microservice on top of mlisp's `-distrib` layer:
    NZB and PAR2 distribution via email, search via `-request` queries.
    Planned as a plaintext email command protocol (consistent with
    existing mlisp `-request` convention) with optional JSON reply
    bodies for machine consumption.")
