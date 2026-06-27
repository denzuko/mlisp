# CLAUDE.md — mlisp

AI assistant context for this repository.

## Project

`mlisp` is a zero-dependency SBCL/Roswell mailing list manager.
Architecture: email as actor-based pub/sub over RFC 2822 infrastructure.
Mail queue = FIFO broker. $MAILDIR/new/ = task queue.
Mailing list = topic namespace. Per-message binary = stateless worker actor.
fetchmail = consumer. sendmail = publish.

Do not import web/chat latency assumptions into this domain.
Email is inherently asynchronous; latency inside the SMTP transaction
is invisible to users. The RFC 6783 address is the pub/sub coordination
primitive; mlisp is the list manager, not an orchestration layer.

## Semver

- MAJOR — public API/CLI interface break only (wire protocol, .asd exports)
- MINOR — new non-breaking capability
- PATCH — everything else; freely exceeds 100; never bump MAJOR for restructuring

## Workflow (BDD-first)

Order is mandatory. Specs and policy drive code, never the reverse.

1. Open a GitHub Issue
2. Branch: `feat/N-description` or `fix/N-description`
3. Write or update FiveAM spec(s) in `test/fiveam/`
4. Write or update BATS integration test(s) in `test/bats/`
5. Write or fix code until all specs pass (`qlot exec ros run --load mlisp-test.asd`)
6. Update `CHANGELOG.md` under `[Unreleased]`
7. Push → PR → review → squash merge to `develop`, then `develop` → `main`
8. Semver tag on `main`

Never commit directly to `develop` or `main`.
Never merge without explicit approval.
If specs or policy direction is unclear, stop and ask.

## Standards in force

- BSD 2-Clause Licence (see `LICENSE`)
- `net.matrix` CMDB identity in `src/matrix-id.lisp` — baked into binary
  at compile time via `defparameter` constants; version from `.asd` at
  read time via `#.`
- `policy/slsa.rego` — SLSA provenance gate (CI context input)
- `.github/workflows/slsa.yml` — SLSA Level 3 provenance pipeline
- FiveAM specs are the behavioural contract; BATS covers integration
- No OPA AST gate (no clang AST for Lisp); FiveAM spec count is the
  coverage signal

## net.matrix identity

DPS-constant values live in `src/matrix-id.lisp`.
Per-binary values (`version`) are resolved at compile time via
`#.(asdf:component-version (asdf:find-system :mlisp))`.
`strings(1)` on the compiled binary must surface all `net.matrix.*` keys.

## Architecture rules

- mlisp implements actor-based pub/sub over RFC-standard email infrastructure
- No `system()`, `popen()`, or `exec*()` equivalents except where the
  actor contract requires subprocess dispatch (filters, MTA handoff)
- Procmail DSL is the filter pipeline; mlisp does not own filter logic
- Q3 2026 roadmap: anonymous side-channel networks over SMTP,
  P2P mesh (FidoNet-style), anonymous remailers (Type I/II)

## Repository layout

```
src/           — core Lisp source
test/fiveam/   — FiveAM behavioural specs
test/bats/     — BATS integration tests
policy/        — OPA Rego gates (CI context only)
etc/           — deployment configs, procmail samples
templates/     — RFC 2822 message templates
```
