# Security Policy

## Supported Versions

| Version | Supported |
|---|---|
| 0.2.x | ✅ |
| 0.1.x | ❌ |

## Reporting a Vulnerability

**Do not open a public GitHub Issue for security vulnerabilities.**

Email: denzuko@dapla.net  
Subject: `[mlisp SECURITY] brief description`

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Any suggested fix

You will receive acknowledgement within 5 business days. Disclosure
will be coordinated after a fix is available.

## Threat Model

mlisp processes untrusted email from stdin and writes to a local
S-expression database. Key security properties:

- No network listening; attack surface is stdin only
- No `system()`, `popen()`, or `exec*()` calls in core logic
- State file should be chmod 600, owned by the MTA user
- `sendmail` path is configurable via `MLISP_SENDMAIL`; ensure it
  points to a trusted binary
- `MLISP_HOME` controls state and template paths; ensure the directory
  is not world-writable
