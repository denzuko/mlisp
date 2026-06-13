# Contributing to mlisp

Patches are submitted by email to the development list.  No GitHub account
required.  No web UI required.  The workflow is the one the Linux kernel,
Git, and OpenBSD have used for decades: format a patch, send it to the list,
discuss it on the list, maintainer applies it.

If the project also mirrors to GitHub, pull requests remain functional —
the maintainer may apply them via `git am` from the PR's email notification.
Patches submitted by email take precedence.

## Branch model (GitFlow)

- **`main`** — release branch. Tagged (`vX.Y.Z`) for releases; the
  release workflow (`.github/workflows/release.yml`) builds and attaches
  platform packages on tag push. Nothing is committed directly to `main`
  except merge commits from `develop` at release time.
- **`develop`** — integration branch. All feature/fix work targets `develop`.
- **Topic branches** — `feat/<issue>-<slug>`, `fix/<issue>-<slug>`,
  `chore/...`, `refactor/...`, `ci/...`, `build/...`, branched from and
  PR'd back to `develop`.
- Periodically, `develop` is merged to `main` and tagged for a release.

## Merge authority

**PRs (including those opened by an AI assistant/agent) are opened for
review and left open. CI passing is necessary but not sufficient —
merging requires the maintainer's explicit go-ahead.** An assistant
working on this repo must not run `gh pr merge` (with or without
`--admin`) on its own initiative, even when all checks are green. Open
the PR, report CI status, and stop.

## BDD spec requirement

Every change requires tests written **before** the implementation:

1. Write a failing BATS spec (`test/bats/`) or FiveAM unit test
2. Confirm it fails (RED)
3. Implement the minimum code to pass it
4. Run the full suite: `make test`
5. No exceptions

See existing specs for conventions. New features: BATS integration spec.
Bug fixes: regression spec that reproduces the bug.

## One-time git setup

```sh
git config format.subjectPrefix "PATCH mlisp"
git config sendemail.to "mlisp-devel@lists.example.com"
git config sendemail.confirm always
git config sendemail.chainreplyto false
```

See `.gitconfig.sample` and `doc/send-email-setup.md` for MUA-specific
configuration (msmtp, mutt, aerc, Thunderbird, Gmail relay).

## Submitting a patch

```sh
# Single commit:
git send-email HEAD~1

# Patch series (3 commits) with cover letter:
git format-patch --cover-letter -3 HEAD
# edit 0000-cover-letter.patch
git send-email 0000-*.patch 000[1-3]-*.patch

# Revised version after feedback:
git send-email --reroll-count=2 HEAD~1
# Subject: [PATCH v2] your change
```

## Patch conventions

- **Commit message**: `component: short description` (imperative mood)
- **Body**: explain the motivation — what problem, what was wrong, what changed
- **Sign-off**: `git commit --signoff` (Developer Certificate of Origin)
- **One logical change per patch**: a series is better than one large patch
- **Tests first**: spec before code, always

## Developer Certificate of Origin

`git commit --signoff` certifies that the contribution is your own work
or based on compatible licensed prior work and you have the right to
submit it under BSD-2-Clause.

## Review process

Reply inline to the patch email on the list. Use scissors to separate
comments from quoted patch text:

```
> +    (when (probe-file pgm)

This should also check execute permission.

--- >8 ---
Reviewed-by: Your Name <email@example.com>
```

Accepted tags: `Reviewed-by:`, `Acked-by:`, `Tested-by:`, `Fixes: #N`.

## Applying patches (maintainers)

```sh
git am < patch.eml         # from saved email
git am < *.patch           # from format-patch output
make test                  # run full suite before push
```

## Self-hosting

To run this workflow without GitHub:

1. Host a bare git repo (any POSIX host, no root needed)
2. Deploy `hooks/post-receive.sample` as the post-receive hook
3. Configure `hooks/post-receive.conf` with your -commits list address
4. Set up mlisp with `add-namespace` for your project lists
5. Run `mlisp-admin install-procmail` on your mail host

See `doc/migration-github.md` for the full migration path, including
cgit setup, mlisp-bugs issue tracking, and public-inbox archiving.

## Bug reports

File bugs by emailing the `-bugs-submit` address (once mlisp-bugs is
deployed, issue #69). Until then: email -devel with `[BUG]` in the subject.
