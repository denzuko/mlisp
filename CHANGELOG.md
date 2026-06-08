# Changelog

## [0.3.0] — Unreleased

### Added
- **MIME inbound** (`src/mime.lisp`): strip HTML/multipart from inbound; outbound always 7-bit ASCII
- **BCC delivery**: individual sendmail per subscriber; To: shows list address only
- **RFC 2369 headers**: List-Unsubscribe, List-Subscribe, List-Post, List-Help, X-BeenThere, X-Mailing-List, Precedence: list
- **-request addresses**: per-list command-only endpoint; `--mode request` CLI flag
- **Bounce management** (`src/bounce.lisp`): RFC 3464 DSN detection; bounce-count threshold removal; `show-bounces`/`clear-bounces`
- **Auto-subscribe**: `:auto-subscribe t` per list; `set-option` admin command
- **Prometheus metrics** (`src/metrics.lisp`): OpenMetrics textfile; node_exporter compatible
- **MDN/RRT headers**: `Disposition-Notification-To` + `Return-Receipt-To` on command replies (RFC 8098/3461)
- **Unsubscribe synonyms**: `remove me`, `remove`, `signoff`, `opt-out` all trigger unsubscribe
- **Daemon discrimination** (`src/daemon.lisp`): drop Return-Path: <>, MAILER-DAEMON, Auto-Submitted, Precedence: junk/bulk
- **Dedup** (`src/dedup.lisp`): 24h Message-Id ring buffer per list; `show-dedup`/`clear-dedup`
- **Moderator queue** (`src/modqueue.lisp`): held queue + `approve`/`reject`/`hold-queue` admin commands
- **Digest mode** (`src/modqueue.lisp`): buffer + `flush-digest`; numbered Vol/Issue; cron-compatible
- **Exploder** (`src/exploder.lisp`): list-of-lists fan-out; per-member RFC 2369 headers
- **Maildir** (`src/maildir.lisp`): write-only Maildir spool for notmuch/mutt; atomic tmp→new
- **mlisp-distrib** (`src/distrib.lisp`): new binary; MIME base64 file attachment distribution
- **Hash at rest** (`src/gpg.lisp`): pure-CL SHA-256; `:hash-contacts t` stores only address digest
- **GPG require-signed**: `:require-signed t` rejects unsigned posts; `gpg(1)` verification
- **procmail integration**: `etc/procmailrc.sample`; `mlisp-admin install-procmail` with FROM_DAEMON guards
- **XDG config** (`~/.config/mlisp/`): full XDG Base Dir Spec path resolution
- **`--home` flag**: CLI override for all path resolution
- **mlisp-admin**: 20+ subcommands covering all list/subscriber/config management
- **ASDF systems**: `mlisp.asd`, `mlisp-test.asd`, `mlisp-admin.asd`, `mlisp-distrib.asd`

### Test coverage: 275 tests (78 FiveAM + 197 BATS)

[0.3.0]: https://github.com/denzuko/mlisp/compare/v0.2.0...HEAD

All notable changes to mlisp are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-06-08

### Added
- CAN-SPAM § 7704 compliance: physical postal address and unsubscribe
  instructions in every distributed message footer
- Subject line tagging `[list-id]` on outbound messages (§ 7704(a)(1))
- GDPR Art.7 consent record: subscriber entries now store
  `:subscribed-at` (ISO-8601) and `:consent-method`
- GDPR Art.30 ROPA: `state/audit.sexp` append-only event log
  (subscribe, unsubscribe, post-distributed, post-rejected events)
- GDPR Art.17 erasure: unsubscribe removes address immediately and
  writes erasure event to audit log
- CASL / LGPD / PECR / UK-GDPR coverage via same consent + erasure path
- Templates: `{discuss,announce,devel}.footer.sexp` compliance footers
- 23 new BATS compliance tests; FiveAM suite expanded to 53 tests

### Changed
- Subscriber records promoted from flat strings to plists with consent
  metadata (state schema change — re-seed from `state/state.sexp`)
- `distribute-message` now appends compliance footer to every outbound
  message body and rewrites Subject header with list tag

## [0.1.0] - 2026-06-08

### Added
- Initial implementation: standalone SBCL binary replacing smartlist
- S-expression state engine (`state/state.sexp`) with discuss/announce/devel
- RFC 2822 header parser with CRLF tolerance
- Loop detection via `X-Loop-List-<Name>` headers
- Subscriber management: subscribe / unsubscribe / help commands
- Routing to `denzuko+mlist-<list>@panix.com` drop addresses
- troff -ms DSL compiled through `groff -ms -Tutf8 -P-c`
- Nine template files (welcome/help/goodbye × 3 lists)
- `MLISP_HOME` and `MLISP_SENDMAIL` runtime env-var overrides
- FiveAM unit tests (40), BATS integration (21), BATS regression (8)

[Unreleased]: https://github.com/denzuko/mlisp/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/denzuko/mlisp/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/denzuko/mlisp/releases/tag/v0.1.0

## [Unreleased]

### Added
- `etc/procmailrc.sample` — canonical sample procmail recipe file with one
  block per configured list; use as reference or with install-procmail
- `mlisp-admin install-procmail [--list <id>] [--dry-run]` — appends procmail
  recipes to `~/.procmailrc` (creates file if absent); idempotent (skips
  lists already present); `--list` filters to one list; `--dry-run` prints
  without writing; uses `# mlisp: <id>` comment as idempotency marker
- XDG Base Dir Spec path resolution for state and templates
  (`$XDG_CONFIG_HOME/mlisp/`, `~/.config/mlisp/`, binary dir fallback)
- `--home <dir>` CLI flag on both `mlisp` and `mlisp-admin` (highest priority)
- `mlisp-admin` management binary with subcommands: `show-config`, `init`,
  `list-lists`, `add-list`, `rm-list`, `list-subs`, `add-sub`, `rm-sub`
- `mlisp-admin.asd` ASDF system definition
- `build-admin.lisp` standalone build script
- 29 new BATS specs (`test/bats/test_mlisp_config.bats`)

### Fixed
- `parse-common-flags` do-loop double-advance on `--home` value token
- `cmd-init` path resolution (missing trailing slash in `merge-pathnames`)
- Format strings with `~/` escaped as `~~/` (SBCL `~/fn/` directive parse)
- `mta.lisp` `from-addr` IGNORE style-warning causing ASDF load abort
