# Email-to-SOAP Hello World

A standalone Common Lisp application where email is the transport layer
for a SOAP API. No HTTP. No external SOAP endpoint. The service
implements the operations itself, in-process; email is the only wire
protocol in both directions.

```
Client MUA                   SMTP / mailing list            soap-service
   |                                |                             |
   |-- email (SOAP envelope) ------>|                             |
   |                                |-- stdin (RFC 5322) -------->|
   |                                |               parse XML     |
   |                                |               dispatch op   |
   |                                |               build reply   |
   |<-- email (SOAP response) ------+----- sendmail(8) ----------|
```

The mailing list address (`soap-calc@example.com`) is created by mlisp.
Everything else is standalone -- the service has no dependency on mlisp's
internals.

## Files

```
soap-service       shell wrapper (invokes soap-service.lisp via SBCL)
soap-service.lisp  the service: RFC 5322 parser, SOAP XML parser,
                   calculator dispatch, SOAP envelope builder, sendmail reply
```

## Quick start

```sh
# 1. Create the list address with mlisp (one-time setup)
mlisp-admin add-namespace soap soap@example.com
mlisp-admin set-option soap-calc drop-address soap-calc@example.com

# 2. Route inbound mail to the service via procmail:
#
#    :0
#    * ^To:.*soap-calc@example\.com
#    | /path/to/examples/soap-hello-world/soap-service

# 3. Test the service directly (no mail server needed):
printf 'From: client@example.com\nTo: soap-calc@example.com\nSubject: test\n\n%s\n' \
  '<?xml version="1.0"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"
               xmlns:cal="http://example.com/soap/calculator/">
  <soap:Body>
    <cal:Add>
      <cal:intA>3</cal:intA>
      <cal:intB>4</cal:intB>
    </cal:Add>
  </soap:Body>
</soap:Envelope>' \
  | MLISP_SENDMAIL=/bin/cat ./soap-service
```

## Supported operations

Namespace: `http://example.com/soap/calculator/`

| Operation  | Parameters   | Response element  |
|------------|-------------|-------------------|
| Add        | intA, intB  | AddResult         |
| Subtract   | intA, intB  | SubtractResult    |
| Multiply   | intA, intB  | MultiplyResult    |
| Divide     | intA, intB  | DivideResult      |

Division by zero and unknown operations return a `soap:Fault`.

## Message format

**Request** (client → service):

```
From: client@example.com
To:   soap-calc@example.com
Subject: SOAP Calculator
Content-Type: text/xml; charset=utf-8

<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"
               xmlns:cal="http://example.com/soap/calculator/">
  <soap:Body>
    <cal:Add>
      <cal:intA>3</cal:intA>
      <cal:intB>4</cal:intB>
    </cal:Add>
  </soap:Body>
</soap:Envelope>
```

**Response** (service → client):

```
From: soap-calc@example.com
To:   client@example.com
Subject: Re: SOAP Calculator
Content-Type: text/xml; charset=utf-8

<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"
               xmlns:cal="http://example.com/soap/calculator/">
  <soap:Body>
    <cal:AddResponse>
      <cal:AddResult>7</cal:AddResult>
    </cal:AddResponse>
  </soap:Body>
</soap:Envelope>
```

## Environment

```
MLISP_SENDMAIL        sendmail(8) binary path
                      default: /usr/sbin/sendmail

SOAP_SERVICE_ADDRESS  From: address used in replies
                      default: soap-calc@example.com
```

## Requirements

- SBCL
- sendmail(8) or compatible (Postfix, Exim, OpenSMTPD)
- No external Quicklisp packages -- pure SBCL + built-ins

## Implementation notes

The XML parser in `soap-service.lisp` is a minimal recursive descent
parser sufficient for well-formed SOAP 1.1 envelopes with namespace
prefixes. It handles the subset needed for this use case (no CDATA,
no DTD, no mixed content beyond SOAP's expected structure). For
production use, replace with `xmls` or `cxml` via Quicklisp.
