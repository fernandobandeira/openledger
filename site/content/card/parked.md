# Parked: the card reference product's schema

**Nothing here is applied by any migration.** `migrations/00001_baseline.sql` is the ledger core and
only the ledger core.

## What is in here

`schema.sql` — the authorization, hold and clearing half of the old
`schema/schema.sql`. **Every executable statement is verbatim** — diffed against
`git show 525ada2:schema/schema.sql`, statement by statement, with whitespace and comments
normalised: 24 of the file's 25 statements appear in the original unchanged. The twenty-fifth is
new, and so is some of the commentary: a `DO` block at the top that refuses to load if the core's
`refuse_mutation()`, `refuse_truncate()` or `openledger_app` are absent, added because a bare
`psql -f` against a coreless database stranded four tables and an enum. So: verbatim DDL, plus a
load guard and a header that were not in the original.

| | |
| --- | --- |
| `auth_event_kind` | the seven-value enum for a processor message |
| `card_auth_events` | the append-only log of processor messages — the hold *is* a `SUM` over it |
| `card_auth_event_group` | which authorization a message belongs to, as a revisable bitemporal *inference* rather than a column |
| `card_hold_groups` | the materialised per-group total the ~1 s authorization decision reads |
| `webhook_deliveries` | HTTP-layer redelivery dedup, deliberately separate from ledger identity |
| `card_auth_unmatched`, `card_hold_drift` | the review queue and the alarm |
| 2 append-only triggers, 10 indexes, 7 CHECKs, 1 foreign key, 4 GRANTs, 1 REVOKE | Measured, not asserted: load `migrations/00001_baseline.sql` then this file into an empty database and the counts move by exactly that. The 10 indexes are 4 primary keys plus 6 `CREATE INDEX`. The one foreign key is `card_auth_event_group → card_auth_events`; none crosses into the core, in either direction. An earlier version of this row said "4 indexes" three lines above a sentence saying ten, and listed neither the CHECKs, the foreign key nor the REVOKE. |

Its design is [ADR-0001](/card/decisions/0001-authorization-holds), which is unaffected —
the decision stands, the DDL is just not deployed.

## Why it is parked rather than shipped

**Because [ADR-0003](/decisions/0003-migrations) forbids editing an applied migration,
and this DDL has recorded, unfixed defects.**
[ADR-0001 §*Known, and not fixed*](/card/decisions/0001-authorization-holds#known-and-not-fixed)
lists open findings in this model, **at least four of which under-reserve credit** — the failure this
project calls the cardinal sin. `migrations/00001_baseline.sql` has been applied to real databases.
Had these tables shipped inside it, every one of those defects would now be frozen into an
immutable migration, fixable only by a second migration that alters DDL nothing has ever read. **A
file nothing installs can be rewritten in place.** That is the whole argument, and it is the one
written into [ADR-0008](/decisions/0008-module-boundaries).

**An earlier version of this section gave a reason that does not survive its own evidence.** It
blamed ADR-0001's open findings directly — "shipping DDL whose known defects are recorded and unfixed
is how a schema accumulates state nobody can safely change later". But those findings were recorded
before the split and nothing about them changed on the day of it; and ADR-0001's own header says the
code that would read these tables does not exist. **Empty tables accumulate no state.** The findings
are why the DDL must stay editable. The migration rule is why "shipped" and "editable" cannot both be
true.

The cost of a wallet or marketplace deployment carrying four tables, two views, ten indexes and an
enum it never writes to is real, and it is *not* why this file is here — it is cheap, and
[ADR-0008's alternative (a)](/decisions/0008-module-boundaries) says so.

**And parking does not deliver what [ADR-0008](/decisions/0008-module-boundaries)
wanted, which is removability.** A `card` schema gives you `DROP SCHEMA card CASCADE` — one
statement, verified to leave every core table, foreign key and view intact. A parked file gives you a
file nothing installs, nothing loads and nothing tests. Those are not the same property, and this
directory buys the weaker one. It is recorded as open in
[the decision log](/decisions#still-open).

So: the design is kept, the evidence is kept, the DDL is kept and stays editable, and the database
stays clean until someone invests the time.

## What has to happen before it comes back

1. **[ADR-0008](/decisions/0008-module-boundaries) gets applied** — these objects move
   into their own `card` PostgreSQL schema so the module is *removable* (`DROP SCHEMA card CASCADE`)
   rather than merely unused, and the collision test that ADR requires gets written. 0009 is still
   `proposed`.
2. **It becomes a second migration, not an edit to 00001.** `00001_baseline.sql` has been applied to
   real databases by then; changing an applied migration is not a thing you get to do.
3. **The three core objects it leans on stay put** — `refuse_mutation()`, `refuse_truncate()` and the
   `openledger_app` role. They are in the core migration, and this file will not load without them.
4. **The credit line it decides against gets designed.** The authorization path reads
   `credit_lines`, and **no shipped schema has ever defined it** — not this file, not
   `migrations/00001_baseline.sql`. (`spikes/002-sqlc-vs-jet/schema.sql` does define one; it is a
   spike artefact that never graduated, and [spike 007](/spikes/007-go-or-rust) had to
   add a minimal one of its own before either implementation could run the hot path. An earlier
   version of this line said "no version of this schema has ever defined it", which is wrong about
   the spikes.) The hold *log* is built; the limit it is checked against is not.
