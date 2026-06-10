# Changelog

All notable changes to mlisp are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.6.1] - 2026-06-10

### Added
- **Quicklisp dist** (`dist/`): self-hosted distribution at
  `http://panix.com/~denzuko/dist/mlisp/distinfo.txt`.
  `make dist` generates from HEAD; `make dist-upload` rsyncs to panix.com.
  Resolves the Debian packaging Quicklisp dependency — build scripts already
  conditionally load Quicklisp when present and fall through to bare ASDF.
- **contrib/mlisp.el**: Emacs minor mode for mlisp administration.
  Shell-out backend (default): calls `mlisp-admin` binary directly.
  SLIME/vlime backend (`mlisp-use-slime t`): evaluates in connected SBCL image.
  16 `M-x mlisp-*` commands; completing-read on live list IDs; `set-option`
  completion over all known keys. `(mlisp-setup-keys "C-c m")` binds all
  commands under a prefix key.
- **Makefile**: `dist`, `dist-upload`, `dist-clean` targets.

[0.6.1]: https://github.com/denzuko/mlisp/compare/v0.6.0...v0.6.1
## [0.6.0] - 2026-06-10

### Added
- **Subscriber self-service commands** (`src/requests.lisp`): `info`, `who`
  (gated by `:advertised`), `query` (own settings), `set mail|nomail|digest`
- **BITNET-style archive search** (`src/requests.lisp`): `search <keyword>`,
  `index`, `get <list> <N>` against Maildir archives; `:search-enabled` per list
- **AllFix file distribution** (`src/state.lisp`): `files` command (FILES.BBS),
  `mlisp-admin hatch` (add file + announce); `:distrib-files` state tracking
- **Plugin filter pipeline** (`src/filters.lisp`): `:pre-filter` and
  `:post-filter` hooks; exit codes 0=pass 1=reject 2=hold 3=discard;
  space-separated filter chains; `invoke-filter-chain` / `invoke-single-filter`
- **Example filters**: `etc/filters/spamassassin`, `etc/filters/clamav`,
  `etc/filters/gemini-archive`, `etc/unsubscribe-cgi/unsub.sh`
- **mlisp-admin hatch**: add file to distrib archive + announce to subscribers
- 27 new BATS specs (`test_mlisp_v06.bats` + `test_mlisp_filters.bats`)

### Fixed
- `string-trim " \t"` trimming literal `t` from filter paths — fixed to
  `(list #\Space #\Tab)` (classic CL footgun: `\t` in a string is `\` + `t`)
- `string-to-message`: CRLF normalisation — strip `\r` before header parsing
- `sb-posix:getpid` replaced with `(random 99999)` for standalone binary compat
- Duplicate `windowed-increment-bounce` removed from `diagnose.lisp`
- Forward declarations added to `distrib.lisp`, `metrics.lisp`
- `*compile-file-failure-behaviour*` set to `:warn` in all build scripts

### Test coverage: 416 tests (78 FiveAM + 338 BATS)

## [0.5.0] - 2026-06-09

### Added
- **9 subgroups**: `:owner` (forward-only), `:security` (embargo-capable),
  `:commits` (bot-post-only), `:users` (subscriber-writable) added to namespace model
- **Attachment policy**: `:attachment-policy allow|strip|reject` per list
- **Subject keyword filtering**: `:subject-allow` / `:subject-deny` patterns;
  action `:hold|:reject|:discard`
- **Message sequence numbering**: `:message-numbering t` adds `[list #NNN]`
- **CSV subscriber export**: `mlisp-admin export-csv`; RFC 4180 with consent metadata
- **List management ops**: `rename-list`, `copy-list`, `list-stats`
- **Per-sender rate limiting**: rolling 24h window; `:max-posts-per-day N`;
  action `:hold|:reject|:discard`; `state/ratelimit/` cache
- **Embargo mode**: `mlisp-admin embargo <list> <ISO8601>` / `release-embargo`
- **DKIM-Signature stripped** on redistribution (RFC 6376 §5)
- **Authentication-Results** preserved as `X-Original-Authentication-Results`
- **RFC 8058 one-click unsubscribe**: `List-Unsubscribe-Post` when
  `:unsubscribe-url` configured; HTTPS URI first in `List-Unsubscribe`
- **List-Id domain** derived from `:drop-address` (not hardcoded)
- **List-Archive** and **List-Owner** headers when configured
- **Complete manpages**: `mlisp(1)`, `mlisp-admin(1)`, `mlisp-intro(7)`,
  `mlisp-distrib(1)`; `make man` target
- 37 new BATS specs (`test_mlisp_v05.bats`)

### Test coverage: 402 tests (78 FiveAM + 324 BATS)

## [0.4.0] - 2026-06-09

### Added
- **SHA-256 hash contacts at rest**: `:hash-contacts t`; pure-CL SHA-256
- **GPG require-signed**: `:require-signed t`; `gpg(1)` verification
- **DMARC rewrite**: `:dmarc-rewrite auto|always|never`; DNS `_dmarc.` TXT lookup;
  From-rewrite for `p=reject`/`p=quarantine` domains
- **VERP bounce attribution**: VERP-encoded envelope sender; `verp-decode`
- **LDIF export**: `export-ldif`; RFC 2849 `groupOfNames` for LDAP sync
- **Diagnosis**: `mlisp-admin diagnose`; health report by email or stdout
- **Double opt-in confirmation** (`src/confirm.lisp`): 32-char hex token;
  configurable expiry (`:confirm-window-hours`); `:confirm-subscribe t|nil`
- **Mass subscribe**: `add-sub-batch` (stdin or file, `Name <addr>` format)
- **Multigram bounce threshold**: time-windowed (`:bounce-window-days`);
  soft-bounce tracking; resets window on gap
- 37 new BATS specs across two suites

### Test coverage: 365 tests (78 FiveAM + 287 BATS)

## [0.3.0] - 2026-06-08

### Added
- **MIME inbound** (`src/mime.lisp`): strip HTML/multipart; outbound 7-bit ASCII
- **BCC delivery**: individual `sendmail(8)` per subscriber
- **RFC 2369 headers**: `List-Unsubscribe`, `List-Subscribe`, `List-Post`,
  `List-Help`, `X-BeenThere`, `X-Mailing-List`, `Precedence: list`
- **`-request` addresses**: per-list command endpoint; `--mode request` flag
- **Bounce management** (`src/bounce.lisp`): RFC 3464 DSN; threshold removal
- **Auto-subscribe**: `:auto-subscribe t`
- **Prometheus metrics** (`src/metrics.lisp`): OpenMetrics textfile
- **Daemon discrimination** (`src/daemon.lisp`): drops `Return-Path: <>`,
  `MAILER-DAEMON`, `Auto-Submitted`, `Precedence: junk/bulk`
- **Dedup** (`src/dedup.lisp`): 24h Message-ID ring buffer; `show-dedup`/`clear-dedup`
- **Moderator queue** (`src/modqueue.lisp`): `approve`/`reject`/`hold-queue`
- **Digest mode**: buffer + `flush-digest`; numbered Vol/Issue
- **Exploder** (`src/exploder.lisp`): list-of-lists fan-out
- **Maildir** (`src/maildir.lisp`): write-only Maildir archive
- **mlisp-distrib** (`src/distrib.lisp`): MIME base64 file distribution binary
- **procmail integration**: `etc/procmailrc.sample`; `install-procmail`
- **XDG config**: `~/.config/mlisp/` default; `--home` override
- **mlisp-admin**: 20+ subcommands

### Test coverage: 275 tests (78 FiveAM + 197 BATS)

## [0.2.0] - 2026-06-08

### Added
- CAN-SPAM § 7704 compliance: postal address + unsubscribe in every footer
- Subject tagging `[list-id]` on outbound messages
- GDPR Art.7 consent record: `:subscribed-at` + `:consent-method`
- GDPR Art.30 ROPA: `state/audit.sexp` append-only event log
- GDPR Art.17 erasure: unsubscribe writes erasure event
- CASL / LGPD / PECR / UK-GDPR coverage via same path
- 23 new BATS compliance tests

### Test coverage: 175 tests (53 FiveAM + 122 BATS)

## [0.1.0] - 2026-06-08

### Added
- Initial implementation: standalone SBCL binary replacing smartlist
- S-expression state engine (`state/state.sexp`)
- RFC 2822 header parser with CRLF tolerance
- Loop detection via `X-Loop-List-<Name>` headers
- subscribe / unsubscribe / help commands
- troff -ms DSL templates
- `MLISP_HOME` and `MLISP_SENDMAIL` runtime overrides
- FiveAM unit tests (40), BATS integration (21), BATS regression (8)

### Test coverage: 69 tests

[0.6.0]: https://github.com/denzuko/mlisp/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/denzuko/mlisp/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/denzuko/mlisp/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/denzuko/mlisp/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/denzuko/mlisp/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/denzuko/mlisp/releases/tag/v0.1.0
