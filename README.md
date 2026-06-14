# mlisp — Common Lisp Mailing List Manager

A production-grade replacement for **smartlist** and **Mailman 2** in a
procmail-based MTA environment. Ships as five self-contained SBCL binaries
(no daemon, no interpreter at runtime). State is plain S-expression files.

> **Not sure if this replaces your setup?**
> — If you run `procmail` as your MDA and currently use smartlist, ezmlm,
> Mailman 2, or hand-rolled `procmailrc` recipes to manage mailing lists,
> mlisp replaces all of that. If you run Mailman 3, Sympa, or LISTSERV on
> a full SMTP stack, mlisp is not a drop-in — it targets the same MTA-pipe
> niche as smartlist, not the web-admin niche.

## Status

**v0.8.0** · 381 BATS integration tests · 78 FiveAM unit tests · Actively developed

```
v0.1  Core delivery, subscribe/unsubscribe, troff templates
v0.2  Compliance (CAN-SPAM, GDPR, CASL, LGPD), audit log
v0.3  MIME, BCC delivery, RFC 2369 headers, bounce management,
      Prometheus metrics, Maildir, mlisp-distrib binary
v0.4  SHA-256 contacts, GPG require-signed, procmail integration,
      DMARC rewrite, VERP,
      LDIF export, double opt-in, mass subscribe, bounce thresholds
v0.5  9 subgroups, attachment policy, subject filtering, message
      numbering, rate limiting, embargo, DKIM strip, RFC 8058,
      complete manpages, Quicklisp dist
v0.6  Subscriber self-service (info/who/query/set), BITNET-style
      archive search, AllFix file distribution, plugin filter pipeline,
      Emacs mlisp.el minor mode
v0.7  mlisp-bugs: Debbugs-compatible email bug tracker
v0.8  mlisp-procmail-gen (s-expr DSL for procmailrc), neural.sh
      digest-summarization integration, multi-platform release packages
      (Linux tarball + pkgsrc, NetBSD pkgsrc, FreeBSD pkg),
      automated GitHub Releases, XDG-compliant zero-config init
```

## Binaries

| Binary | Purpose |
|---|---|
| `mlisp` | MTA-pipe delivery: distributes mail, handles subscriber commands and bounces |
| `mlisp-admin` | Operator tool: list management, moderation, export, diagnostics |
| `mlisp-bugs` | Debbugs-compatible email bug tracker (submit/close/control/append) |
| `mlisp-distrib` | AllFix-compatible file distribution |
| `mlisp-procmail-gen` | Compiles s-expr recipe files to procmailrc fragments |

## Quick start

```sh
# 1. Build (requires SBCL + Quicklisp; groff for manpages; bats-core to test)
make build-all

# 2. Install
sudo make install PREFIX=/usr/local

# 3. Init (zero-config: writes to ~/.config/mlisp/ by default)
mlisp-admin init

# 4. Create a namespace (one command creates all subgroup lists)
mlisp-admin add-namespace myproject myproject@lists.example.com

# 5. Generate procmailrc recipes
mlisp-procmail-gen --output ~/.procmailrc etc/example-recipes.lisp
# -- or -- for each list individually:
mlisp-admin install-procmail

# 6. Diagnose
mlisp-admin diagnose myproject-discuss
```

`MLISP_HOME` is optional. `mlisp-admin init` resolves the config directory
in priority order: `--home` flag > `$MLISP_HOME` > `$XDG_CONFIG_HOME/mlisp/`
> `~/.config/mlisp/` > `/etc/mlisp/` (system-wide fallback for service
accounts with no resolvable home directory).

## Architecture

```
procmail → mlisp <list-id>               # delivery: stdin → subscribers
         → mlisp --mode request <list>   # subscriber self-service commands
         → mlisp --mode bounce  <list>   # DSN bounce processing
         → mlisp-bugs --mode submit <pkg>   # bug report submission
         → mlisp-bugs --mode control <pkg>  # bug state changes

mlisp-admin <subcommand>                 # operator: config, moderation, export
mlisp-distrib <list-id> <file>           # file distribution (AllFix-compatible)
mlisp-procmail-gen <recipe.lisp>         # procmailrc DSL compiler
```

All state lives under `$MLISP_HOME` (default: `~/.config/mlisp/`),
except per-list/per-package Maildir archives (see below):

```
state/state.sexp      list configs + subscriber database
state/audit.sexp      append-only event log
state/held/           moderation queue
state/pending/        double opt-in confirmation tokens
state/maildir/        per-list/per-package archive fallback when
                      $MAILDIR is unset (search/index/get, mlisp-bugs)
state/distrib/        file distribution archives
templates/            welcome / goodbye / help / footer templates
etc/filters/          example pre/post filter scripts
etc/unsubscribe-cgi/  RFC 8058 one-click CGI example
```

## Maildir archive location

mlisp's internal per-list archive (used by the `search`/`index`/`get`
subscriber commands and by `mlisp-bugs`) follows the POSIX/
freedesktop.org `$MAILDIR` convention also honored by smartlist,
procmail, debbugs, and notmuch:

```
$MAILDIR set:    $MAILDIR/lists/<list-id>/        e.g. $MAILDIR/lists/mlisp-discuss/
$MAILDIR unset:  $MLISP_HOME/state/maildir/<list-id>/
```

Set `$MAILDIR` to point mlisp's archive at an existing mail spool
shared with other tools (notmuch indexing, mutt, debbugs). With no
`$MAILDIR`, mlisp works zero-config under `$MLISP_HOME`.

`$MAIL` (the mbox-format equivalent) is not used: mlisp only writes
Maildir-format archives.

This is separate from the per-list `set-option <list> maildir-path
<path>` mechanism, which writes an *additional* explicit-path copy for
external indexing regardless of `$MAILDIR`.

## Namespace model

```
myproject-discuss    subscriber-writable general discussion
myproject-announce   owner-post-only notifications
myproject-devel      patches, VCS, development traffic
myproject-distrib    file/binary distribution (AllFix)
myproject-request    admin commands (subscribe/unsubscribe/help/search/…)
myproject-owner      off-list owner contact
myproject-security   security disclosures (GPG + embargo support)
myproject-commits    automated CI/VCS notifications (bot-post-only)
myproject-users      end-user support
```

One `mlisp-admin add-namespace myproject myproject@lists.example.com`
creates all nine lists. Use `--subgroups` to create a subset.

## procmailrc DSL (mlisp-procmail-gen)

Write recipes as s-expressions:

```lisp
(:recipe :marker  "mlisp: myproject-discuss"
         :guards  ("!^FROM_DAEMON" "!^FROM_MAILER"
                   "!^Precedence: (bulk|junk|list)")
         :match   "^^TO_myproject-discuss@lists.example.com"
         :pipe    "/usr/local/bin/mlisp --home /etc/mlisp myproject-discuss")
```

```sh
mlisp-procmail-gen --output ~/.procmailrc recipes.lisp   # idempotent append
mlisp-procmail-gen --dry-run recipes.lisp                # preview only
```

## Bug tracker (mlisp-bugs)

```sh
mlisp-admin bugs-add-package myproject bugs-submit@lists.example.com
mlisp-admin install-bugs-procmail myproject

# Operator tools
mlisp-admin bugs-list myproject --open --severity critical
mlisp-admin bugs-report myproject
mlisp-admin bugs-show myproject 42
```

Wire format: `<pkg>-bugs-submit@`, `<pkg>-bugs-N@`, `<pkg>-bugs-N-done@`,
`<pkg>-bugs-control@`. Same as Debbugs.

## Plugin filters

```sh
# Exit codes: 0=pass  1=reject  2=hold  3=discard
mlisp-admin set-option mylist pre-filter  /path/to/filter
mlisp-admin set-option mylist post-filter /path/to/filter

# Space-separated chain: first non-zero stops processing
mlisp-admin set-option mylist pre-filter "/etc/mlisp/filters/spam /etc/mlisp/filters/virus"
```

Bundled examples in `etc/filters/`: SpamAssassin, ClamAV, Gemini archive.

## neural.sh integration (digest/report summarization)

`neural` is the vendored `vendor/neural.sh` submodule's own build
output: a self-contained shell script (bash + curl + jq + jo at
runtime). `make build-all` runs `make -C vendor/neural.sh build` and
copies the result to `bin/neural` alongside the mlisp binaries;
`make install` installs it to `PREFIX/bin/`.

```sh
# First-time setup: install build/runtime deps (curl, jq, jo, m4 --
# m4 is vendor/neural.sh's own build dependency, used internally)
make deps

# Build everything including neural
make build-all

# Summarize a bug report
OPENAI_API_KEY=sk-... mlisp-admin bugs-report myproject \
    --summarize etc/filters/neural-summarize
```

The model/endpoint are whatever `vendor/neural.sh` was built with --
its default is OpenAI `text-davinci-003`, requiring `OPENAI_API_KEY`.
See `vendor/neural.sh`'s own docs to change the model/endpoint.

## Key `set-option` keys

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
maildir-path         /path/to/dir  (explicit external archive copy for
                     notmuch/mutt; independent of $MAILDIR -- see
                     "Maildir archive location" below)
pre-filter           /path/to/filter
post-filter          /path/to/filter
```

## Subscriber commands (via -request address)

```
subscribe [subgroup]    info           who [list]
unsubscribe             query [list]   set <list> mail|nomail|digest
help                    search <kw>    index [list]
nomail / resume         get <list> N   files [list]
confirm <token>         diagnose
```

## Migration

**From smartlist:** `mlisp-admin add-sub-batch mylist subscribers-file`

**From Mailman 2:**
```sh
list_members -o members.txt mylist
mlisp-admin add-sub-batch myproject-discuss members.txt
```

## Testing

Tests are split by role:

- **FiveAM** (`make test-unit`) — primary BDD/unit tests for core library
  logic (`src/*.lisp`): message parsing, state machine, compliance rules,
  MIME handling. 78 specs. These are the source-of-truth for behavioral
  correctness.
- **BATS** (`make test-bats`) — integration tests that exercise the compiled
  binaries end-to-end via subprocess calls. 381 specs across 19 suites.
  Catches binary/CLI-level regressions.

```sh
make test-unit   # FiveAM: 78 unit specs
make test-bats   # BATS: 381 integration specs across 19 suites
```

## Documentation

```
man mlisp               delivery pipeline reference
man mlisp-admin         all admin subcommands + set-option keys
man mlisp-intro         tutorial + migration from smartlist/Mailman/LISTSERV
man mlisp-distrib       file distribution
```

## Requirements

- SBCL 2.x with Quicklisp
- groff (for template rendering)
- bats-core (for the integration test suite)
- fiveam via Quicklisp (for the unit test suite)
- POSIX sendmail(8) or compatible (Postfix, Exim, OpenSMTPD)
- procmail (for MTA integration)
- m4, jo, jq, curl (build-time, for `vendor/neural.sh`; bash + curl + jq + jo at runtime for the `neural` binary)

## Release packages

Pre-built binaries for each GitHub Release:

| Package | Format |
|---|---|
| `mlisp-<ver>-linux-x86_64.tar.gz` | Generic Linux tarball |
| `mlisp-<ver>-linux-x86_64.tgz` | pkgsrc binary package |
| `mlisp-<ver>-netbsd-x86_64.tgz` | NetBSD pkgsrc binary package |
| `mlisp-<ver>-freebsd-x86_64.pkg` | FreeBSD native package |

## License

BSD-2-Clause — Da Planet Security / Dwight Spencer
