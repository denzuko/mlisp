# Email as Agent-Based Pub/Sub Infrastructure

## Summary

SMTP/email mailing list infrastructure is a proven, RFC-standardised
actor-based publish/subscribe system with 40+ years of operational
history. It replaces over-engineered broker-dependent systems (Redis +
Celery, Kafka, RabbitMQ) with zero-dependency, zero-supply-chain-attack
infrastructure that scales from a regional user group to the Linux
kernel mailing list.

## The Actor Model Over Email

```
fetchmail / MTA inbound          ← pull primitive (replaces broker poll)
   ↓
$MAILDIR/new/                    ← FIFO queue (guaranteed order, MTA-managed)
   ↓
procmail / MDA delivery          ← message routing / filter chain
   ↓
mlisp (per-message binary)       ← stateless worker actor (receives one message,
   ↓                                produces side effects: reply, archive, filter)
sendmail / MTA outbound          ← publish to subscribers
   ↓
mailing list namespaces          ← topic namespacing / access control / archival
```

Each component maps to a conventional pub/sub primitive:

| Email infrastructure        | Conventional pub/sub equivalent         |
|-----------------------------|----------------------------------------|
| Mail queue (MTA spool)      | FIFO message broker                    |
| `$MAILDIR/new/`             | Consumer inbox / task queue            |
| Mailing list address        | Topic / channel namespace              |
| Subscriber list             | Consumer group / topic subscription    |
| procmail recipe             | Message filter / router                |
| Per-message binary (mlisp)  | Stateless worker / actor               |
| fetchmail                   | Poll-based consumer / puller           |
| SMTP reply                  | Publish to topic / produce message     |
| `-distrib` subgroup         | Fanout exchange                        |
| `-request` subgroup         | Command/query channel                  |
| `-announce` subgroup        | Broadcast / notification channel       |
| mlisp-bugs                  | Specialised stateful consumer          |
| Message archive (Maildir)   | Persistent log / event store           |
| `X-Loop:` header            | Deduplication / idempotency key        |
| DKIM/SPF/DMARC + TLS        | Authentication + transport security    |

## Why This Is Better Than Redis+Celery / Kafka

**No supply chain attack surface.** The mlisp stack's runtime is SBCL
(30-year lineage) and POSIX utilities. Protocol dependencies are IETF
RFCs. A Redis+Celery deployment depends on: Redis, the Celery package,
transitive Python dependencies, serialisation libraries, broker
configuration, and deployment tooling. Each is a supply chain attack
vector. Email has none of these.

**No broker.** The MTA is the broker and it already exists for sending
and receiving email. There is no separate service to operate, monitor,
or secure.

**40 years of operational excellence.** BITNET/LISTSERV (1981)
established the namespace and routing model. FidoNet (1984) proved
store-and-forward at scale with intermittent connectivity, heterogeneous
nodes, and no central broker. SMTP + DKIM + TLS formalised what both
already knew operationally. The Linux kernel mailing list (~2,000
messages/day at peak) runs on this infrastructure without a message
broker.

**Latency is irrelevant.** Email is inherently asynchronous. The
standard user experience is: send a message, receive a reply later.
Processing time inside the SMTP transaction (seconds to tens of seconds)
is invisible to users. Importing web/chat latency expectations into an
email domain is a category error.

**Natural backpressure.** The MTA queue provides natural flow control.
Messages are stored until the worker is ready. No consumer group
rebalancing, no partition assignment, no offset management.

**Zero-trust by default.** DKIM provides message-level integrity and
sender authentication. SPF and DMARC enforce sender policy at the DNS
layer. TLS encrypts transport. mlisp's subscriber ACL enforces access
control at the list level. No additional auth infrastructure required.

## Historical Lineage

- **BITNET/LISTSERV (1981)**: First large-scale email list management
  system. Established: namespace model, subscriber management, archival,
  digest mode, command dispatch via `-request` address pattern.

- **FidoNet (1984)**: Store-and-forward at scale with heterogeneous
  nodes and intermittent connectivity. Proved the model works without
  central brokers across 30,000+ nodes globally.

- **Majordomo / Mailman (1990s)**: Generalised LISTSERV patterns to
  open-source UNIX. Established the `-request`/`-owner`/`-announce`
  subgroup convention that mlisp inherits.

- **debbugs (Debian, 1994)**: Specialised list-based bug tracker. Proves
  that stateful workflows (bug lifecycle: submit → append → close) are
  expressible over email without a database-backed web service.

- **mlisp (2024)**: Reimplements the full stack in
  Common Lisp as six self-contained SBCL binaries. Adds: per-message
  filter pipeline, neural.sh integration, yEnc/PAR2 binary distribution,
  microservice composability via the subscriber model.

## mlisp-Specific Architecture

### Subgroup Namespacing

mlisp creates a namespace of related list addresses per topic:

```
<ns>-discuss@domain   ← main subscriber list (general posts)
<ns>-announce@domain  ← broadcast-only (owner posts only)
<ns>-request@domain   ← command channel (subscribe/unsubscribe/ask/search)
<ns>-owner@domain     ← moderation / administration
<ns>-distrib@domain   ← binary file distribution (AllFix/yEnc)
<ns>-bugs@domain      ← bug tracker intake (debbugs-compatible)
```

### Microservice Composition

Microservices are subscribers on one or more list addresses. They follow
the same batch cron + Maildir pattern:

```
*/5 * * * *  fetchmail → $MAILDIR/new/  → microservice binary
```

The microservice:
1. Reads all unread messages from `$MAILDIR/new/`
2. Filters by `X-Loop:` (skip own replies) and `Content-Type`
3. Dispatches on message content (SOAP envelope, distrib segment, command)
4. Sends reply via sendmail (to list or direct, per RFC 2369 routing)
5. Marks messages read: `new/` → `cur/` (Maildir convention)

**Implemented microservices in this codebase:**
- `examples/soap-hello-world/` — W3C SOAP 1.2 Email Binding calculator
- `examples/nzb-indexer/` — NZB release indexer for `-distrib` segments

### Reply Routing (W3C SOAP 1.2 Email Binding §4.2.3)

Microservices discover the correct reply address from RFC 2369/2919
list headers automatically:

- `List-Id:`, `List-Post:`, `Mailing-List:`, or `Precedence: list`
  present → reply to **list address** (1:many, all subscribers receive
  the response; downstream service consumers can act on it)
- None of the above → reply to **From:** address (1:1 private exchange)

This implements the consumer/subscriber duality: the same microservice
handles both direct queries and list-broadcast responses without flags
or configuration.

## When to Use This Pattern

**Use email pub/sub when:**
- Delivery guarantee matters more than throughput (email has MTA-level
  retry; Celery tasks can be lost on worker crash without persistence)
- The audience is heterogeneous (humans + services, any MUA works)
- Security posture requires minimal attack surface
- The team already operates email infrastructure
- Async workflows with human-in-the-loop steps are needed
- Auditability is required (every message is archived)

**Don't use email pub/sub when:**
- Sub-second latency is required (use NATS, ZeroMQ, etc.)
- Messages are too large for SMTP (use chunked distribution via
  `-distrib` + yEnc, or out-of-band data transfer with email as
  the control plane)
- Binary payloads need to be carried inline (use MIME/base64 up to
  ~750KB per segment, yEnc for larger with mlisp-distrib chunking)

## Future Work (Q3 2026+)

The architecture extends naturally to:
- **Anonymous side-channel networks**: Mixmaster/Type II remailer chains
  over SMTP; mlisp lists as the delivery endpoint
- **P2P mesh networks**: FidoNet-style store-and-forward with mlisp
  nodes; each node is a subscriber on its peers' announce lists
- **Anonymous remailers**: Type I (Cypherpunk) and Type II (Mixmaster)
  remailers are already email-based; mlisp provides the list management
  layer at the exit node
- **Standardisation**: This architecture is a candidate for privacy-respecting
  infrastructure standards in civil liberties and activist organisations

## References

- RFC 2369 — The Use of URLs as Meta-Syntax for Core Mail List Commands
- RFC 2919 — List-Id: A Structured Field and Namespace for the Identification of Mailing Lists
- RFC 5321 — Simple Mail Transfer Protocol
- RFC 5322 — Internet Message Format
- RFC 6376 — DomainKeys Identified Mail (DKIM)
- RFC 7208 — Sender Policy Framework (SPF)
- RFC 7489 — Domain-based Message Authentication, Reporting, and Conformance (DMARC)
- RFC 8461 — SMTP MTA Strict Transport Security (MTA-STS)
- W3C SOAP 1.2 Email Binding (NOTE, 3 July 2002)
- Bernstein, D.J. — qmail and Maildir specification
- FidoNet Technical Standards Committee — FTS-0001 (Basic FidoNet Protocol)
