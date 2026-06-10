# Migrating from GitHub to self-hosted git + mlisp

This guide covers migrating a project's primary home from GitHub (or any
platform host: GitLab, Gitea, Sourcehut) to a self-hosted git repository
with cgit for web browsing and mlisp for mailing lists and issue tracking.

**Why:** GitHub's Terms of Service permit using public repository content
to train AI models. Contributors' code, commit messages, and issue
discussions are ingested without consent. Self-hosting returns control of
the project's intellectual property to the project and its contributors.

## The target stack

```
git (bare repo)       version control, code hosting
cgit                  web interface, clone URLs, patch download
mlisp                 mailing lists (-devel, -announce, -bugs, etc.)
mlisp-bugs            issue tracker (Debbugs-compatible email protocol)
git send-email        patch submission
public-inbox          searchable list archive (HTTP + NNTP + Atom)
```

All of this runs on any POSIX host with procmail and a sendmail-compatible
MTA. No root required beyond normal user operations.

## Step 1: Set up the bare git repository

```sh
# On your server:
mkdir -p ~/repos
git init --bare ~/repos/myproject.git

# Set description (shown by cgit):
echo "My project — short description" > ~/repos/myproject.git/description

# Set owner for cgit display:
git -C ~/repos/myproject.git config gitweb.owner "Your Name <you@example.com>"
```

## Step 2: Push all history from GitHub

```sh
# On your local machine:
git remote add self user@host:repos/myproject.git
git push self --mirror

# Verify:
git ls-remote self | head -5
```

## Step 3: Set primary remote, keep GitHub as read-only mirror

```sh
# Set your server as the primary push/pull remote:
git remote set-url origin user@host:repos/myproject.git

# Keep GitHub as a secondary mirror (optional):
git remote add github https://github.com/user/myproject
git remote set-url --push github https://github.com/user/myproject

# Push to both with one command using a push alias:
git config remote.all.url user@host:repos/myproject.git
git config --add remote.all.pushurl user@host:repos/myproject.git
git config --add remote.all.pushurl https://github.com/user/myproject
# Then: git push all
```

## Step 4: Set up cgit (web interface)

Install cgit on the server (no root required if installed to ~/bin):

```sh
# Debian/Ubuntu: apt install cgit
# FreeBSD: pkg install cgit
# From source: https://git.zx2c4.com/cgit/

# ~/.cgitrc (or /etc/cgitrc):
virtual-root=/
repo.url=myproject
repo.path=/home/user/repos/myproject.git
repo.desc=My project
repo.owner=user@example.com
repo.clone-url=https://example.com/repos/myproject.git
                ssh://user@example.com/repos/myproject.git
```

On panix.com, cgit can run as a CGI script under `public_html/cgi-bin/`.
See panix.com's CGI documentation for `.htaccess` configuration.

## Step 5: Set up mlisp lists

```sh
export MLISP_HOME=~/.config/mlisp
mlisp-admin init
mlisp-admin add-namespace myproject myproject@lists.example.com
mlisp-admin install-procmail

# Configure for public project:
mlisp-admin set-option myproject-discuss dmarc-rewrite auto
mlisp-admin set-option myproject-discuss confirm-subscribe true
mlisp-admin set-option myproject-discuss unsubscribe-url \
  https://lists.example.com/unsub/myproject-discuss

# Configure -commits for CI notifications (bot-post-only):
mlisp-admin set-option myproject-commits bot-address ci@example.com
```

## Step 6: Deploy CI hook

```sh
cp ci/run-tests.sh ~/repos/myproject.git/ci/
cp hooks/post-receive.sample ~/repos/myproject.git/hooks/post-receive
chmod +x ~/repos/myproject.git/hooks/post-receive

# Configure the hook:
cat > ~/repos/myproject.git/hooks/post-receive.conf << 'EOF'
CI_PROJECT="myproject"
CI_BRANCH="main"
CI_COMMITS_ADDRESS="myproject-commits@lists.example.com"
CI_BUGS_ADDRESS="myproject-bugs-submit@lists.example.com"
CI_FROM="ci@lists.example.com"
EOF
```

## Step 7: Set up public-inbox (optional but recommended)

public-inbox provides a searchable HTTP/NNTP archive for your lists.
Install it once and configure each list as a post-filter:

```sh
# Install: https://public-inbox.org/README
public-inbox-init myproject-devel \
  ~/mail/archives/myproject-devel \
  https://lists.example.com/myproject-devel \
  myproject-devel@lists.example.com

# Wire as mlisp post-filter:
mlisp-admin set-option myproject-devel \
  post-filter /usr/local/lib/mlisp/filters/public-inbox-inject

# etc/filters/public-inbox-inject:
#!/bin/sh
public-inbox-mda --address myproject-devel@lists.example.com
cat  # pass through unchanged
```

## Step 8: Update project documentation

```sh
# README.md: update clone URL
# Change: https://github.com/user/myproject
# To:     https://example.com/repos/myproject.git
#         ssh://user@example.com/repos/myproject.git

# CONTRIBUTING.md: update list address
# Point to mlisp-devel@lists.example.com

# Leave GitHub URL in place but add a note:
# "Primary: https://example.com/repos/myproject.git
#  Mirror: https://github.com/user/myproject (read-only)"
```

## Step 9: Announce the migration

Post to your -announce list:

```
Subject: [ANN] Primary repository moved to example.com

The primary repository for myproject has moved to:
  https://example.com/repos/myproject.git

The GitHub repository at https://github.com/user/myproject will
remain as a read-only mirror.

Update your remotes:
  git remote set-url origin https://example.com/repos/myproject.git

Patches via email to myproject-devel@lists.example.com.
Issues via email to myproject-bugs-submit@lists.example.com.
```

## Migration from MailChimp / Posterius / Constant Contact

Export your subscriber list from the platform (usually CSV), then:

```sh
mlisp-admin add-sub-batch myproject-announce subscribers.csv
mlisp-admin set-option myproject-announce non-member-action reject
mlisp-admin set-option myproject-announce dmarc-rewrite auto
mlisp-admin set-option myproject-announce \
  unsubscribe-url https://lists.example.com/unsub/myproject-announce
```

Key difference from commercial platforms: mlisp does not track opens or
clicks. This is intentional — subscriber behavior data stays private.

## Migration from Mailman 2

```sh
list_members -o members.txt mylist
mlisp-admin add-sub-batch myproject-discuss members.txt
```

Map Mailman config to mlisp set-option keys per `man mlisp-intro` section 13.

## Migration from smartlist

```sh
mlisp-admin add-sub-batch mylist-discuss .list/mylist
```

Map smartlist config per `man mlisp-intro` section 12.

## Migration from LISTSERV

Send `QUIET REVIEW listname SHORT` to your LISTSERV, parse the response,
pipe to `mlisp-admin add-sub-batch`. LISTSERV subscriber command set
(`info`, `who`, `query`, `set`, `search`, `index`, `get`) is fully
implemented in mlisp via the -request address.

## Privacy and IP considerations

When you self-host with this stack:

- Subscriber addresses stay on your server
- List archives are under your control — public-inbox TLP:WHITE archives
  are opt-in per list; private lists have no public archive
- Commit history and issue discussions cannot be scraped by AI companies
  without explicit permission
- GDPR consent records are in `state/audit.sexp` on your server
- You cannot be de-platformed by a Terms of Service change
- Legal demands (subpoenas, DMCA) go to you directly, not to a platform
  that may comply silently
