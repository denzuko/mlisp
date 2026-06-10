---
title: "mlisp: Replacing Mailman with 416 Tests and No Daemon"
date: 2026-06-10
tags: [infosec, selfhosted, foss]
---

The mailing list manager running most open-source projects today is Mailman 2,
which had its last meaningful release in 2015 and requires Python 2.7 to install
cleanly. The replacement, Mailman 3, requires Django, a SQL database, a REST API
process, and a separate WSGI server. I run my mail on panix.com. None of that
is available to me.

So I wrote a replacement.

[mlisp](https://github.com/denzuko/mlisp) is a compiled SBCL Common Lisp binary
that replaces Mailman 2 and smartlist entirely. It processes one message per
invocation, pipes through sendmail, and stores all state as S-expressions. No
daemon. No database. No HTTP server. 416 tests.

## The architecture constraint that shapes everything

Panix is a shared Unix host. The MTA is Sendmail. Delivery is procmail. I cannot
run a daemon, open a port, or install system packages. Every design decision
flows from this.

The traditional smartlist architecture fits: a procmail recipe pipes each inbound
message to a program that reads stdin, processes it, calls sendmail for each
subscriber, and exits. The program is stateless from the OS perspective — all
state lives in files that persist between invocations.

mlisp follows this exactly. Three binaries:

```
mlisp          — delivery agent (one invocation per inbound message)
mlisp-admin    — configuration and moderation CLI
mlisp-distrib  — file distribution (AllFix-compatible)
```

A fourth (`mlisp-bugs`) is in progress: a Debbugs-compatible email bug tracker
using the same architecture.

## State as S-expressions

Every list, subscriber, audit event, pending confirmation token, held message,
and per-sender rate-limit window lives in `$MLISP_HOME/state/`. The subscriber
database:

```lisp
(:id "mlisp-discuss"
 :drop-address "mlisp-discuss@panix.com"
 :description "mlisp development discussion"
 :dmarc-rewrite :auto
 :confirm-subscribe t
 :max-posts-per-day 0
 :pre-filter nil
 :post-filter nil
 :subscribers
 ((:address "alice@example.com"
   :subscribed-at "2026-06-01T12:00:00Z"
   :consent-method "double-opt-in"
   :bounce-count 0)))
```

This is human-readable, grep-able, and version-controllable. `mlisp-admin
show-config mlisp-discuss` prints it formatted. `git diff state/state.sexp`
shows exactly what changed and when.

## The namespace model

smartlist ran one binary per list address. mlisp uses a namespace-subgroup model
where a single `add-namespace` command creates nine addresses at once:

```
mlisp-discuss    subscriber-writable discussion
mlisp-announce   owner-post-only notifications
mlisp-devel      patches and development
mlisp-distrib    file releases (AllFix-compatible)
mlisp-request    subscriber commands
mlisp-owner      operator escalation (never subscriber-visible)
mlisp-security   security reports (GPG + embargo)
mlisp-commits    CI/VCS notifications (bot-post-only)
mlisp-users      end-user support
```

The `:commits` subgroup accepts posts only from a configured bot address and
bypasses the subscriber check entirely. The `:security` subgroup holds all posts
under embargo until a release date set by `mlisp-admin embargo`. These are
routing decisions, not access control theater.

## The processing pipeline

Every inbound message runs through the same sequence:

```
0.  Max message size check
1.  Loop detection (X-BeenThere)
2.  Daemon discrimination (null envelope, MAILER-DAEMON, Auto-Submitted)
3.  Duplicate suppression (24h Message-ID ring buffer)
3y. Attachment policy (allow / strip / reject)
3z0. Subject keyword filtering (allow/deny patterns + action)
3z1. Per-sender rate limiting (rolling 24h window)
3z. List locking
3x. Pre-filter hook (plugin pipeline, exit 0/1/2/3)
4.  Subgroup routing (:request / :announce / :owner / :commits / :security / :distrib)
5.  GPG signature check
6.  Moderation queue
7.  Auto-subscribe
8.  Subscriber check
9.  Digest buffering
10. Distribution
      → Post-filter hook
      → DKIM-Signature stripped (RFC 6376 §5)
      → DMARC rewrite (DNS lookup, p=reject/quarantine domains only)
      → VERP envelope sender
      → RFC 2369/2919/8058 headers
      → One sendmail(8) call per subscriber
```

The pre-filter and post-filter hooks are executable programs with a four-exit-code
contract. Exit 0 passes the message through with stdout as the new message. Exit 1
rejects. Exit 2 holds for moderation. Exit 3 discards silently. Space-separated
chains run in order; first non-zero stops the chain:

```sh
mlisp-admin set-option mlisp-discuss pre-filter "/path/spamassassin /path/clamav"
```

The filter receives the raw RFC 5322 message on stdin. That is the entire API
surface. SpamAssassin, ClamAV, and a Gemini capsule archiver are included as
example filter scripts in `etc/filters/`.

One subtlety worth noting: mlisp's header parser normalizes field names to
uppercase. A filter script that matches on `Subject:` will not fire; it needs
`SUBJECT:`. This is documented in the manpage and the CHANGELOG. It cost a
debugging session to find.

## DMARC and deliverability

Gmail and Yahoo enforce DMARC strictly since February 2024. A mailing list that
rewrites the envelope but not the From header causes messages from affected
domains to fail DMARC at the receiving end. mlisp queries DNS:

```sh
mlisp-admin set-option mlisp-discuss dmarc-rewrite auto
```

With `:dmarc-rewrite auto`, mlisp looks up `_dmarc.<sender-domain>` and rewrites
`From:` only when the domain publishes `p=reject` or `p=quarantine`. The original
sender address goes to `Reply-To:` and `X-Original-From:`. The outbound message
reads:

```
From: mlisp-discuss via alice@gmail.com <mlisp-discuss@panix.com>
Reply-To: alice@gmail.com
X-Original-From: alice@gmail.com
```

RFC 8058 one-click unsubscribe is a set-option call:

```sh
mlisp-admin set-option mlisp-discuss \
  unsubscribe-url https://lists.panix.com/unsub/mlisp-discuss
```

This adds `List-Unsubscribe-Post: List-Unsubscribe=One-Click` to every outbound
message and puts the HTTPS URI first in `List-Unsubscribe:`. A CGI example that
calls `mlisp-admin rm-sub` on POST is in `etc/unsubscribe-cgi/`.

## Subscriber commands

Subscribers send commands to the `-request` address. The full set, including
the LISTSERV/BITNET commands that Mailman 2 never shipped:

```
subscribe [subgroup]    info           who [list]
unsubscribe             query [list]   set <list> mail|nomail|digest
help                    search <kw>    index [list]
nomail / resume         get <list> N   files [list]
confirm <token>
```

`search <keyword>` does case-insensitive full-text search of the Maildir archive.
`files` returns the distrib archive in AllFix FILES.BBS format. `get <list> N`
retrieves a specific archived message by sequence number. `query` returns the
subscriber's own delivery settings. These work by sending email to the `-request`
address — no web form, no login, no account.

## The test suite structure

416 tests across two frameworks:

**FiveAM (78 tests):** unit tests covering the parser, state functions, MIME
processing, header assembly, and RFC compliance. These run against the Lisp source
before any binary is built.

**BATS (338 tests):** integration tests that build real binaries, send real
messages through real procmail recipes using a stub sendmail, and inspect the
outbound email content. Each test gets a fresh scratch directory with a clean
state.sexp copy. Teardown deletes it. No test state leaks.

The BDD workflow is strict: write the failing spec first, implement the minimum
code to pass it, run the full suite. The `string-trim " \t"` bug from the filter
integration work is the canonical example. In Common Lisp, `"\t"` in a string
literal is backslash followed by `t`, not a tab character. Every filter path
ending in the letter `t` was being silently truncated and failing `probe-file`.
The BATS spec caught it because the filter was not being called and the test
checked for a side effect. The fix was replacing `" \t"` with
`(list #\Space #\Tab)`.

## What's in the issue tracker

**#69 mlisp-bugs** — a Debbugs-compatible email bug tracker using the same
procmail architecture. Four address patterns: `<pkg>-bugs-submit@`,
`<pkg>-bugs-N@`, `<pkg>-bugs-N-done@`, and `<pkg>-bugs-control@`. On submission,
mlisp-bugs assigns a sequential ID and prepends a pseudo-header block to the
outbound message body:

```
Bug#42: memory leak in parser
Package: myproject
Severity: important
Reported-by: alice@example.com
Date: 2026-06-10T09:00:00Z
Message-ID: <abc123@example.com>
```

Control commands arrive as structured plain text to the control address:

```
severity 42 critical
tags 42 + patch
close 42 1.2.1
```

Bug state lives in `state.sexp`. The audit log tracks every status change.
Prometheus metrics gain a `mlisp_bugs_open_total` gauge. No web interface, no
database, no Perl. This is Debbugs minus everything except the protocol.

**#70 bugs-report** — periodic bug status summary emailed to the package owner
address: open count by severity, recently closed, median age, unowned count.
Reads from the audit log.

## Running it

```sh
git clone https://github.com/denzuko/mlisp
cd mlisp
sbcl --non-interactive --load build.lisp
sbcl --non-interactive --load build-admin.lisp
install -m 755 bin/mlisp bin/mlisp-admin /usr/local/bin/

export MLISP_HOME=~/.config/mlisp
mlisp-admin init
mlisp-admin add-namespace myproject myproject@lists.example.com
mlisp-admin install-procmail
mlisp-admin diagnose myproject-discuss
```

The manpages cover everything else: `man mlisp`, `man mlisp-admin`,
`man mlisp-intro`.

The code is BSD-2-Clause. The architecture is designed for shared Unix hosting
because that is where most of the interesting email infrastructure still runs.
