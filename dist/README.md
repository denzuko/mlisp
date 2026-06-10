# mlisp Quicklisp Distribution

Hosted at `http://panix.com/~denzuko/dist/mlisp/` (CNAME: `dist.dapla.net`).

## Install

```lisp
(ql:install-dist "http://panix.com/~denzuko/dist/mlisp/distinfo.txt"
                 :prompt nil)
(ql:quickload :mlisp)
(ql:quickload :mlisp-admin)
```

## Systems

| System | Description |
|---|---|
| `mlisp` | Core delivery agent and state engine |
| `mlisp-admin` | Configuration and moderation CLI functions |
| `mlisp-distrib` | File distribution (AllFix-compatible) |
| `mlisp-bugs` | Debbugs-compatible email bug tracker (in progress) |

## Without Quicklisp

```sh
git clone https://github.com/denzuko/mlisp
cd mlisp
# Add to ASDF search path and load directly:
sbcl --eval '(push #p"/path/to/mlisp/" asdf:*central-registry*)' \
     --eval '(asdf:load-system :mlisp)'
```

## Updating

```lisp
(ql:update-dist "mlisp")
```

## Dist generation (maintainer)

```sh
make dist           # builds dist/ from current HEAD + version tag
make dist-upload    # rsync dist/ to panix.com public_html
```
