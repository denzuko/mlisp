# Contributing to mlisp

## Workflow

1. Open a GitHub Issue describing the problem or feature
2. Branch from `main`: `fix/N-short-description` or `feat/N-short-description`
3. Write failing BDD specs (BATS) **before** touching source
4. Implement the fix; all tests must pass before PR
5. Update `CHANGELOG.md` under `[Unreleased]`
6. Push branch, open PR — review happens on GitHub, not local merge
7. After merge, tag is cut by maintainer

## Commit messages

```
type(scope): short description under 72 chars

Body wrapping at 72 chars.
Reference issue with Fixes #N.
```

Types: `feat`, `fix`, `test`, `docs`, `chore`, `refactor`, `security`

## Test requirements

Every PR must pass all four suites:

```sh
make test
```

| Suite | File | Covers |
|---|---|---|
| FiveAM | `test/fiveam/test-mlisp.lisp` | Unit: parser, state, DSL |
| BATS integration | `test/bats/test_mlisp.bats` | Pipeline end-to-end |
| BATS regression | `test/bats/test_mlisp_regression.bats` | Known regression cases |
| BATS compliance | `test/bats/test_mlisp_compliance.bats` | CAN-SPAM / GDPR / CASL |

New compliance-affecting changes require new BATS specs in
`test_mlisp_compliance.bats` citing the specific statute and section.

## Compliance rule

Any change to `distribute-message`, subscriber state, or template
rendering must include a compliance review comment citing the relevant
statute. Do not remove the postal address footer, unsubscribe
mechanism, audit log writes, or consent metadata.

## Branch protection

- `main` is protected; direct push forbidden
- All checks must pass; at least one review required
- Linear history (rebase before PR)

## Code of Conduct

See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
