# mlisp — Compiled SBCL Mailing List Manager

A production-grade, compiled Common Lisp replacement for **smartlist** and
**Mailman 2** in a procmail-based MTA environment. State is stored as plain
S-expression files; every message processes through a single-binary delivery
pipeline with no daemon required.

## Status

**v0.6.0** · 416 tests passing · Actively developed

```
v0.1  Core delivery, subscribe/unsubscribe, troff templates
v0.2  Compliance (CAN-SPAM, GDPR, CASL), audit log
v0.3  MIME, BCC delivery, RFC 2369 headers, bounce management,
      Prometheus metrics, Maildir, mlisp-distrib binary
v0.4  SHA-256 contacts, GPG require-signed, procmail integration,
      DMARC rewrite, VERP, LDIF export, double opt-in, mass subscribe
v0.5  9 subgroups, attachment policy, subject filtering, message
      numbering, rate limiting, embargo, DKIM strip, RFC 8058
v0.6  Subscriber self-service (info/who/query/set), BITNET-style
      archive search, AllFix file distribution, plugin filter pipeline
```

## Quick start

```sh
# Build (requires SBCL + Quicklisp + groff + bats)
sbcl --non-interactive --load build.lisp
sbcl --non-interactive --load build-admin.lisp
install -m 755 bin/mlisp bin/mlisp-admin /usr/local/bin/

# Initialise and create a namespace
export MLISP_HOME=~/.config/mlisp
mlisp-admin init
mlisp-admin add-namespace myproject myproject@lists.example.com
mlisp-admin install-procmail
mlisp-admin diagnose myproject-discuss
```

## Architecture

```
procmail → mlisp <list-id>    # delivery: stdin → subscriber distribution
         → mlisp --mode request mlisp-request   # subscriber commands
         → mlisp --mode bounce  mlisp-discuss    # DSN bounce processing

mlisp-admin <subcommand>      # configuration, moderation, export
mlisp-distrib <list-id> <file> # file distribution (AllFix-compatible)
```

All state lives under `$MLISP_HOME`:

```
state/state.sexp      list configs + subscriber database
state/audit.sexp      append-only event log
state/held/           moderation queue
state/pending/        double opt-in tokens
state/maildir/        message archive (for search/index/get)
state/distrib/        file distribution archives
templates/            welcome / goodbye / help / footer templates
etc/filters/          example pre/post filter scripts
etc/unsubscribe-cgi/  RFC 8058 one-click CGI example
```

## Namespace model

```
mlisp-discuss    subscriber-writable general discussion
mlisp-announce   owner-post-only notifications
mlisp-devel      patches, VCS, development
mlisp-distrib    file/binary distribution
mlisp-request    admin commands (subscribe/unsubscribe/help/search/…)
mlisp-owner      off-list owner contact
mlisp-security   security disclosures (GPG + embargo)
mlisp-commits    automated CI/VCS notifications (bot-post-only)
mlisp-users      end-user support
```

## Subscriber commands (via -request address)

```
subscribe [subgroup]       info           who [list]
unsubscribe                query [list]   set <list> mail|nomail|digest
help                       search <kw>    index [list]
nomail / resume            get <list> N   files [list]
confirm <token>            diagnose
```

## Plugin filters

```sh
# Pre-filter: runs before all processing
# exit 0=pass  1=reject  2=hold  3=discard
mlisp-admin set-option mylist pre-filter /path/to/filter

# Post-filter: runs after headers assembled, before sendmail
mlisp-admin set-option mylist post-filter /path/to/filter

# Space-separated chains: first non-zero stops the chain
mlisp-admin set-option mylist pre-filter "/path/spam /path/virus"
```

See `etc/filters/` for SpamAssassin, ClamAV, and Gemini archive examples.

## Key set-option keys

```
dmarc-rewrite        never|auto|always
verp                 true|false
confirm-subscribe    true|false
message-numbering    true|false
max-posts-per-day    N
attachment-policy    allow|strip|reject
subject-allow        "pattern"
subject-deny         "pattern"
unsubscribe-url      https://...   (RFC 8058 one-click)
archive-url          https://...   (List-Archive header)
search-enabled       true|false
advertised           true|false
pre-filter           /path/to/filter
post-filter          /path/to/filter
```

## Migration

**From smartlist:** `mlisp-admin add-sub-batch mylist subscribers-file`

**From Mailman 2:**
```sh
list_members -o members.txt mylist
mlisp-admin add-sub-batch myproject-discuss members.txt
```

## Documentation

```
man mlisp           delivery pipeline reference
man mlisp-admin     all admin subcommands + set-option keys
man mlisp-intro     tutorial + migration from smartlist/Mailman/LISTSERV
man mlisp-distrib   file distribution
```

## Requirements

- SBCL 2.x with Quicklisp
- groff (for template rendering)
- bats-core (for the test suite)
- POSIX sendmail(8) or compatible (Postfix, Exim)
- procmail (for MTA integration)

## License

BSD-2-Clause — Da Planet Security / Dwight Spencer
