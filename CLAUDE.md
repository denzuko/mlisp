# CLAUDE.md — mlisp Project Internal Knowledge

This file records architectural decisions, mental models, and context
that should inform all future work on this codebase.

---

## Core Architectural Philosophy

**mlisp implements an actor-based publish/subscribe system over
RFC-standard email infrastructure.** This is not a stylistic choice
or a constraint — it is the design. Every component decision flows
from this.

See `docs/skills/email-pubsub-architecture.md` for the full framing.

### The actor model mapping

```
MTA queue          = FIFO message broker
$MAILDIR/new/      = consumer inbox / task queue  
mailing list       = topic namespace
per-message binary = stateless worker actor
fetchmail          = poll-based consumer
sendmail reply     = publish to topic
X-Loop: header     = deduplication key
```

### Why this is correct

- 40+ years of operational excellence (BITNET → FidoNet → LISTSERV → Majordomo → mlisp)
- Zero supply chain attack surface (SBCL + POSIX + IETF RFCs)
- No broker to operate, monitor, or secure
- Email is inherently async — latency inside the SMTP transaction is invisible to users
- DKIM/SPF/DMARC/TLS provide authentication and transport security at the protocol layer

Do not import web/chat latency expectations into this domain.
Do not propose async refactors for operations that already run inside
an asynchronous email delivery pipeline.

---

## Project Identity

**mlisp** is a minimalist mailing list manager — a smartlist
replacement built around procmail pipes, S-expression state files,
and six self-contained SBCL binaries:

- `mlisp` — per-list delivery (procmail target)
- `mlisp-admin` — list/namespace administration
- `mlisp-bugs` — Debbugs-compatible bug tracker intake
- `mlisp-distrib` — AllFix-compatible file distribution (yEnc/base64)
- `mlisp-procmail-gen` — generates .procmailrc from namespace config
- `neural` — vendored neural.sh build output

**Author:** Dwight Spencer (denzuko), Da Planet Security  
**EIN:** 26-25-39362  
**Repository:** github.com/denzuko/mlisp  
**IANA PEN:** 42387

---

## Workflow Rules

### GitFlow — enforced

- Feature branches → PR → `develop`, never direct commits to develop/main
- `main` = stable release only, updated via develop→main PRs
- Branch naming: `feat/NNN-description`, `fix/NNN-description`,
  `chore/description`, `refactor/description`, `ci/description`
- **Never merge PRs without explicit "ok do it" from Dwight**
- Semver: MAJOR=public API/interface break only. MINOR=new non-breaking
  capability. PATCH=everything else (fixes, docs, build, CI). Patch
  freely exceeds 100. Never bump major for restructuring.

### BDD workflow — mandatory for all C and Lisp projects

Policy gate (Rego) → test (FiveAM/BATS) → code → changelog → merge → tag.
**Never write code before the test.** If direction is unclear, stop and ask.

For mlisp specifically:
- FiveAM for pure Lisp unit specs
- BATS for integration specs (test the compiled binary end-to-end)
- Both suites must pass before a PR is opened
- CI runs both; BATS failure = don't merge

### CI cache management

- Use `(ql:clean)` or explicit ASDF cache directory deletion to clear
  stale fasls. Never `find / -name "*.fasl" | xargs rm`.
- All build scripts (build*.lisp) delete the ASDF output cache before
  loading to prevent stale binary reuse on CI.
- `rm -f bin/mlisp*` before `make build-all` in CI to force clean rebuild.

---

## System Architecture

### Subgroup namespacing

Per namespace `<ns>` at `<domain>`:

```
<ns>-discuss    ← main subscriber list
<ns>-announce   ← owner-post-only broadcast
<ns>-request    ← command channel (subscribe/unsubscribe/ask/search/index)
<ns>-owner      ← moderation
<ns>-distrib    ← binary file distribution
<ns>-bugs       ← bug tracker (debbugs-compatible)
```

### -request command dispatch

Commands are dispatched via subject line or first body line:
`subscribe`, `unsubscribe`, `info`, `who`, `query`, `set`, `search`,
`index`, `get`, `files`, `ask`, `diagnose`, `confirm`.

`ask <question>` — opt-in neural.sh integration. Configured per-list
via `set-option <id> ai-ask <neural-cmd>`. Falls back to list info +
command reference when not configured.

### Filter pipeline

Pre/post-filter hooks exist on both mailing lists and bugs packages:

```
mlisp-admin set-option <list-id> pre-filter <path>
mlisp-admin set-option <list-id> post-filter <path>
mlisp-admin bugs-set-option <pkg> pre-filter <path>
mlisp-admin bugs-set-option <pkg> post-filter <path>
```

Exit codes: 0=pass, 1=reject, 2=hold, 3=discard.
Bundled examples in `etc/filters/`: spamassassin, clamav, gemini-archive,
neural-summarize, neural-moderate.

### Binary distribution (mlisp-distrib)

Files ≤ segment-size-kb: single message, base64, streaming encoder.
Files > segment-size-kb: yEnc multipart segments, subject convention
`[list-id] fname (N/total)`. Segment size default: 750KB.

yEnc encoding: input bytes whose encoded form (byte+42)%256 is
NUL/LF/CR/= are escaped. Escape bytes: 214/224/227/19 (NOT 0/10/13/61).

### Microservice pattern

Microservices are subscribers on list addresses. All follow:

```
*/5 * * * *  fetchmail → $MAILDIR/new/  → microservice binary
```

Processing loop:
1. `maildir-new` — list $MAILDIR/new/
2. Skip X-Loop: matches service address
3. Skip non-matching Content-Type
4. Parse payload, dispatch, send reply via sendmail
5. `mark-read` — mv new/ → cur/ with :2, flags

Reply routing: RFC 2369/2919 list headers present → reply to list (1:many).
No list headers → reply to From: (1:1). Always set X-Loop: on replies.

Implemented:
- `examples/soap-hello-world/` — W3C SOAP 1.2 Email Binding
- `examples/nzb-indexer/` — NZB release indexer for -distrib segments

### ASDF system naming convention

`com.dwightaspencer.<project>/<subsystem>`

Subsystems: `/core`, `/service`, `/tests`, `/doc`

---

## Key Design Constraints

### mlisp.asd — zero dependencies

`mlisp.asd` has `:depends-on ()` by design. mlisp is a near-zero-
dependency CLI tool. 40ants-doc, documentation tools, and example-layer
systems go in separate `.asd` files that depend on `mlisp`, not the
other way around.

### neural.sh integration scope

`neural` is the vendored `vendor/neural.sh` build output. It is:
- Optional everywhere it appears (fallback always exists)
- Never a hard dependency of mlisp.asd
- Called via `pipe-through-command` (subprocess, not FFI)
- Appropriate for local-inference (Ollama, etc.) — not cloud APIs
  given the privacy posture of the typical deployment

### GPG/S-MIME

Deliberately out of scope at the application layer. Handle at the MDA
layer (procmail + gpg) before delivery to $MAILDIR/ if required.
mlisp surfaces DKIM/SPF/DMARC verdicts from Authentication-Results
headers (RFC 7601) — it does not perform cryptographic verification.

---

## Future Roadmap (not yet started)

**Q3 2026 (after Watchers series release):**
- Anonymous side-channel networks over SMTP
- P2P mesh networks (FidoNet-style store-and-forward)  
- Anonymous remailers (Type I/II) with mlisp as list management layer

**Intended audiences:**
- RT4-Albany (privacy advocacy)
- hack.dapla.net (hacker community)
- RT4-TWG (Technology Working Group standard proposal)
- Books/articles building on this work (Watchers series successor volumes)

**#99 (parked):** mlisp-mailman subsystem suite — evaluate when there
is a concrete user requirement.

---

## Deployment Context

Da Planet Security MSSP, Albany NY. mlisp runs on:
- klaxon.dapla.net (Da Planet Radio / Icecast)
- gorkon.dapla.net (IRC, mlisp lists)
- Subscribers include Albany 2600, HPR contributors, aNONradio community

Channel partners with relevant toolchain context: Cloudflare (edge,
DNS), Postfix (MTA), fetchmail/procmail (delivery), SBCL/Quicklisp/qlot
(runtime), Roswell (SBCL version management).
