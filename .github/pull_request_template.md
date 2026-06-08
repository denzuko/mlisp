## Summary

<!-- One sentence describing the change. Reference the issue: Fixes #N -->

## Changes

<!-- Bullet list of what changed -->

## Compliance impact

<!-- Does this change affect distribute-message, subscriber state,
     templates, or audit logging? If yes, cite the statute and confirm
     compliance tests pass. If no, write "None". -->

## Test results

```
make test
```

- [ ] FiveAM: Pass: ___ (100%)
- [ ] BATS integration: ___/21
- [ ] BATS regression: 8/8
- [ ] BATS compliance: 23/23
- [ ] `CHANGELOG.md` updated under `[Unreleased]`

## Checklist

- [ ] Branch is `fix/N-desc` or `feat/N-desc`
- [ ] Commit messages follow `type(scope): description` convention
- [ ] No direct commits to `main`
