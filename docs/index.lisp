;;;; docs/index.lisp — 40ANTS-DOC documentation pages for mlisp
;;;;
;;;; Part of the mlisp-docs ASDF system (mlisp-docs.asd), kept separate
;;;; from mlisp.asd so mlisp itself stays dependency-free (#99).
;;;;
;;;; This is narrative documentation (an entry point + pointers to the
;;;; manpages, which remain the canonical reference), not a full
;;;; symbol-by-symbol API reference -- mlisp is a CLI tool built around
;;;; six binaries (mlisp, mlisp-admin, mlisp-bugs, mlisp-distrib,
;;;; mlisp-procmail-gen, neural), not a library consumed via
;;;; (asdf:load-system :mlisp) by other projects.

(uiop:define-package #:mlisp-docs
  (:use #:cl)
  (:export #:@index)
  (:import-from #:40ants-doc
                #:defsection))

(in-package #:mlisp-docs)


(defsection @index (:title "mlisp"
                    :ignore-words ("API" "ASDF" "CAN-SPAM" "CASL" "CLI"
                                    "DMARC" "FAQ" "GDPR" "MAILDIR" "RAG"
                                    "README" "RFC" "SBCL" "XDG"))
  "mlisp is a minimalist mailing list manager -- a smartlist
   replacement built around procmail pipes, S-expression state files,
   and six self-contained SBCL binaries (`mlisp`, `mlisp-admin`,
   `mlisp-bugs`, `mlisp-distrib`, `mlisp-procmail-gen`, `neural`). It
   processes raw RFC 2822 email from stdin, maintains a subscriber
   database, and enforces CAN-SPAM/GDPR/CASL compliance on every
   outbound message.

   This page is a narrative entry point. The canonical reference is
   the manpage set (`mlisp-intro(7)`, `mlisp(1)`, `mlisp-admin(1)`,
   `mlisp-bugs(1)`, `mlisp-distrib(1)`, `mlisp-procmail-gen(1)`),
   installed alongside the binaries and linked from the README."

  (@quickstart section)
  (@architecture section)
  (@manpages section)
  (@todo section))


(defsection @quickstart (:title "Quick start")
  "See the README's \"Quick start\" section for the zero-config setup
   (`mlisp-admin init`, adding a namespace, wiring procmail).

   The `mlisp` binary is the procmail delivery target: it reads a raw
   RFC 2822 message from stdin and routes it to the list named by its
   sole argument. Run `mlisp --help` for the full usage summary.")


(defsection @architecture (:title "Architecture")
  "mlisp follows a procmail-pipe architecture: there is no daemon or
   persistent process. Each binary is invoked per-message (or per
   admin command) and reads its configuration from an S-expression
   state file under `$MLISP_HOME` (default `~/.config/mlisp/`,
   following the XDG Base Directory spec).

   Per-list/per-package Maildir archives (used by the `search`/
   `index`/`get` subscriber commands and by `mlisp-bugs`) follow the
   `$MAILDIR` convention shared with smartlist, procmail, debbugs, and
   notmuch -- see the README's \"Maildir archive location\" section and
   `mlisp-intro(7)` section 15 for details.

   `neural.sh` integration (`bugs-report --summarize`) is documented in
   the README's \"neural.sh integration\" section.")


(defsection @manpages (:title "Manual pages")
  "mlisp's manpages are the canonical reference and are installed to
   the system manpath alongside the binaries:

   - `mlisp-intro(7)` -- concepts, namespace model, subgroup roles,
     moderation, digests, bounce handling, privacy/GDPR, DMARC,
     migration from smartlist/Mailman, procmail integration, the
     Maildir archive location, plugin filters, subscriber
     self-service commands, and file distribution.
   - `mlisp(1)` -- the per-list delivery binary (procmail target).
   - `mlisp-admin(1)` -- list/namespace administration, the bug
     tracker admin commands, and `set-option` reference.
   - `mlisp-bugs(1)` -- the Debbugs-compatible bug tracker's mail
     intake binary.
   - `mlisp-distrib(1)` -- AllFix-compatible file distribution.
   - `mlisp-procmail-gen(1)` -- generates `.procmailrc` rules from
     mlisp's namespace/subgroup configuration.")


(defsection @todo (:title "What is next")
  "
- Use cases 1-3 of #100 (subscriber-facing FAQ/RAG via neural.sh, bug
  triage assist, moderation pre-screen) -- use case 4 (digest/report
  summarization) shipped via `bugs-report --summarize`.
- #99 (stretch): `mlisp-mailman` subsystem suite (fetchmail/formail/
  metamail/netrc replacements), evaluated per-subsystem against
  mlisp's near-zero-dependency footprint.")
