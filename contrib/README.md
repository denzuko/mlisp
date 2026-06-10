# mlisp.el — Emacs interface to mlisp

Administer mlisp mailing lists from Emacs.  Two backends:

- **Shell-out** (default): calls `mlisp-admin` binary directly.
  Works with any Emacs; no running Lisp image required.
- **SLIME/vlime**: evaluates `mlisp-admin` functions directly in a
  connected SBCL image.  Faster; completion over live state.

## Installation

### Manual

```elisp
(add-to-list 'load-path "/path/to/mlisp/contrib")
(require 'mlisp)
(setq mlisp-home "~/.config/mlisp")
```

### use-package

```elisp
(use-package mlisp
  :load-path "~/src/mlisp/contrib"
  :custom
  (mlisp-home "~/.config/mlisp")
  (mlisp-admin-binary "/usr/local/bin/mlisp-admin")
  :config
  (mlisp-setup-keys "C-c m"))
```

### Via Quicklisp dist (Emacs side)

```elisp
;; Install the CL systems into your SBCL image:
(ql:install-dist "http://panix.com/~denzuko/dist/mlisp/distinfo.txt"
                 :prompt nil)
(ql:quickload :mlisp-admin)

;; Then load the Emacs package:
(add-to-list 'load-path "/path/to/mlisp/contrib")
(require 'mlisp)
(setq mlisp-use-slime t)
```

## Key bindings

With `(mlisp-setup-keys "C-c m")`:

| Key | Command | Description |
|-----|---------|-------------|
| `C-c m l` | `mlisp-list-lists` | All lists with subscriber counts |
| `C-c m c` | `mlisp-show-config` | Configuration for a list |
| `C-c m s` | `mlisp-list-subs` | Subscriber list |
| `C-c m h` | `mlisp-hold-queue` | Held message queue |
| `C-c m a` | `mlisp-approve` | Approve a held message |
| `C-c m r` | `mlisp-reject` | Reject a held message |
| `C-c m +` | `mlisp-add-sub` | Add subscriber |
| `C-c m -` | `mlisp-rm-sub` | Remove subscriber |
| `C-c m o` | `mlisp-set-option` | Set a list option |
| `C-c m d` | `mlisp-diagnose` | Health report |
| `C-c m b` | `mlisp-show-bounces` | Bounce report |
| `C-c m e` | `mlisp-export-csv` | Export subscribers as CSV |
| `C-c m A` | `mlisp-show-audit` | Open audit log |
| `C-c m L` | `mlisp-lock` | Lock list (hold all posts) |
| `C-c m U` | `mlisp-unlock` | Unlock list |
| `C-c m S` | `mlisp-list-stats` | Message statistics |

## SLIME/vlime mode

When `mlisp-use-slime` is `t` and a SLIME or vlime connection is active,
commands evaluate directly in the connected SBCL image.

```elisp
(setq mlisp-use-slime t)
```

The image must have `mlisp-admin` loaded:

```lisp
;; In your SBCL init or slime-repl:
(asdf:load-system :mlisp-admin)
(mlisp:load-state)
```

List IDs are completed from live state.  Changes take effect immediately
without a subprocess round-trip.

## vlime

vlime uses the same SLIME protocol.  The `mlisp--slime-eval` backend
detects which is active:

```vimscript
" In your .vimrc, load mlisp-admin when vlime connects:
autocmd User VlimeConnected call vlime#Send(
  \ vlime#contrib#slynk#EvalAndGrab(
  \   '(asdf:load-system :mlisp-admin) (mlisp:load-state)'))
```
