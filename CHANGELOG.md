# Changelog

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
