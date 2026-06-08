# mlisp — Minimalist Mailing List Processor

A compiled, standalone Common Lisp replacement for the legacy **smartlist** suite.
State is kept as a single S-expression database; formatted mail uses an embedded
troff -ms DSL compiled through `groff`.

## Architecture

```
stdin (raw email)
       │
       ▼
  mlisp <list-id>
       │
       ├─ parse RFC 2822 headers
       ├─ loop-detection (X-Loop-List-<Name>)
       ├─ command dispatch (subscribe / unsubscribe / help)
       ├─ subscriber authorization
       │
       ├─ state.sexp  ←─── S-expression database (lists + subscribers)
       ├─ templates/  ←─── troff DSL S-expression templates
       │
       └─ sendmail(8) → subscribers / requester
```

## Lists

| List ID | Drop Address |
|---|---|
| `discuss` | `denzuko+mlist-discuss@panix.com` |
| `announce` | `denzuko+mlist-announce@panix.com` |
| `devel` | `denzuko+mlist-devel@panix.com` |

## Build

```sh
make build          # produces bin/mlisp
make test           # FiveAM unit + BATS integration
make install PREFIX=/usr/local
```

Requires: `sbcl`, `groff`, `bats`, POSIX `sendmail(8)`.

## MTA wiring (Postfix)

```
# /etc/aliases
mlist-discuss:   "|/usr/local/bin/mlisp discuss"
mlist-announce:  "|/usr/local/bin/mlisp announce"
mlist-devel:     "|/usr/local/bin/mlisp devel"
```

Set `MLISP_HOME` to override default state/template paths.

## Commands (subscriber-initiated)

Send to the list drop address with Subject or first body line containing:
- `subscribe` / `unsubscribe` / `help`

## troff DSL

Templates are S-expression forms compiled to `troff -ms` macros piped through
`groff -ms -Tutf8 -P-c`.

```lisp
(:document
 (:title "My List — Welcome")
 (:section "Welcome")
 (:pp "You are now subscribed.")
 (:raw ".br"))
```

## smartlist Migration

| smartlist | mlisp |
|---|---|
| `text/welcome` | `templates/<list>.welcome.sexp` |
| `text/help` | `templates/<list>.help.sexp` |
| `text/farewell` | `templates/<list>.goodbye.sexp` |
| `subscribers` flat file | `state.sexp :subscribers` |
| `rc.custom` | `src/mlisp.lisp` dispatch |

## License

BSD-2-Clause — Da Planet Security / Dwight Spencer
