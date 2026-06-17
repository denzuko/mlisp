# SOAP 1.2 Email Binding — Hello World

Implementation of the [W3C SOAP Version 1.2 Email Binding](https://www.w3.org/TR/soap12-email/)
(NOTE, 3 July 2002) as a compiled SBCL microservice.

Email is the **only** transport layer. No HTTP, no external SOAP
endpoint. The service runs on a 5-minute cron schedule, batch-processes
all unread messages in its `$MAILDIR/new/`, dispatches SOAP operations
in-process, and replies per smart address discovery.

## Specs implemented

| Spec | Role |
|------|------|
| [W3C SOAP 1.2 Email Binding](https://www.w3.org/TR/soap12-email/) | transport binding framework |
| [RFC 3902](https://www.rfc-editor.org/rfc/rfc3902) | `application/soap+xml` media type (REQUIRED by W3C spec) |
| [RFC 2045](https://www.rfc-editor.org/rfc/rfc2045) | MIME packaging |
| [RFC 5322](https://www.rfc-editor.org/rfc/rfc5322) | internet message format |
| [RFC 2369](https://www.rfc-editor.org/rfc/rfc2369) | `List-Post:`, `List-Id:` mailing list headers |
| [RFC 2919](https://www.rfc-editor.org/rfc/rfc2919) | `List-Id:` header |

## Reply address discovery (no flags required)

The service inspects RFC 2369/2919 mailing list headers on each inbound
message and routes the reply accordingly:

| Inbound headers | Reply to | Pattern |
|-----------------|----------|---------|
| `List-Id:`, `List-Post:`, `Mailing-List:`, `Precedence: list` present | List address (`List-Post:` or `To:`) | 1:many — all list subscribers (and downstream SOAP consumers) receive the response |
| None of the above | Original `From:` address | 1:1 — private exchange |

Per the W3C spec (§4.2.3, Table 9): `In-Reply-To:` is always set to
the request's `Message-ID:` for correlation. `X-Loop:` is set on all
outbound replies to prevent the service reprocessing its own replies
when fetchmail pulls them back into `$MAILDIR/new/`.

## Architecture

```
cron (*/5 * * * *)
  └─ fetchmail → $MAILDIR/new/        (pull unread messages)
  └─ soap-service (this binary)
       for each file in $MAILDIR/new/:
         if X-Loop: == service address → mark read, skip
         if no application/soap+xml Content-Type → mark read, skip
         parse SOAP 1.2 envelope (xmls, in-process)
         dispatch operation (Add/Subtract/Multiply/Divide)
         discover reply address (list vs direct)
         sendmail reply with:
           Content-Type: application/soap+xml (RFC 3902)
           In-Reply-To: <request Message-ID>  (W3C correlation)
           X-Loop: <service address>           (loop guard)
         mv new/msg → cur/msg                 (Maildir mark-read)
```

## Build

```sh
sbcl --noinform --load build.lisp
# Produces: ./soap-service (~45MB, standalone SBCL binary)
```

Requires: SBCL, Quicklisp (`xmls`).

## Setup

```sh
# 1. Create the list address with mlisp
mlisp-admin add-namespace soap soap@example.com
mlisp-admin set-option soap-calc drop-address soap-calc@example.com

# 2. Configure fetchmail (~/.fetchmailrc for the service account):
#    poll mail.example.com protocol IMAP
#        user "soap-calc" password "..." is "soap-svc" here
#        mda "MAILDIR=$HOME/Maildir /path/to/soap-service"
#        keep                           # don't delete on server
#    (or: fetchmail delivers to MDA, cron runs soap-service separately)

# 3. Add to crontab (crontab -e):
*/5 * * * * MAILDIR=$HOME/Maildir SOAP_SERVICE_ADDRESS=soap-calc@example.com /path/to/soap-service
```

## Supported operations

Namespace: `http://example.com/soap/calculator/`

| Operation | Params | Response |
|-----------|--------|----------|
| `Add` | `intA`, `intB` | `AddResult` |
| `Subtract` | `intA`, `intB` | `SubtractResult` |
| `Multiply` | `intA`, `intB` | `MultiplyResult` |
| `Divide` | `intA`, `intB` | `DivideResult` (fault on ÷0) |

Unknown operations and invalid parameters return a `soap:Fault`.

## Message format (per W3C spec)

**Request** (§4.1.1, Table 3):

```
From: caller@example.com
To:   soap-calc@example.com
Message-ID: <unique-id@example.com>
Content-Type: application/soap+xml; charset=utf-8

<?xml version="1.0" encoding="utf-8"?>
<env:Envelope xmlns:env="http://schemas.xmlsoap.org/soap/envelope/"
              xmlns:cal="http://example.com/soap/calculator/">
  <env:Body>
    <cal:Add>
      <cal:intA>3</cal:intA>
      <cal:intB>4</cal:intB>
    </cal:Add>
  </env:Body>
</env:Envelope>
```

**Response** (§4.2.3, Table 9):

```
From: soap-calc@example.com
To:   caller@example.com          (or list address if list-routed)
In-Reply-To: <unique-id@example.com>
X-Loop: soap-calc@example.com
Content-Type: application/soap+xml; charset=utf-8

<?xml version="1.0" encoding="utf-8"?>
<env:Envelope xmlns:env="http://schemas.xmlsoap.org/soap/envelope/"
              xmlns:cal="http://example.com/soap/calculator/">
  <env:Body>
    <cal:AddResponse>
      <cal:AddResult>7</cal:AddResult>
    </cal:AddResponse>
  </env:Body>
</env:Envelope>
```

## Environment

| Variable | Default | Description |
|----------|---------|-------------|
| `MAILDIR` | `~/Maildir` | Maildir root |
| `SOAP_SERVICE_ADDRESS` | `soap-calc@example.com` | `From:` and `X-Loop:` value |
| `MLISP_SENDMAIL` | `/usr/sbin/sendmail` | sendmail binary |
