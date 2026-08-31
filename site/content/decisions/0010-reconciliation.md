# 0010 — Every number with a second copy gets a view that compares them

**Status:** accepted
**Evidence:** [spike 011](/spikes/011-reconciliation) for the views, the drifts and the cost;
[spike 009](/spikes/009-where-the-balance-lives) for why the comparison is independent at all.

## The decision

**Whenever the same fact is written down in two places, something has to actually check that the two
still agree — and here that something is a set of automatic comparisons, run once a day by an account
that is allowed to look at the books but not to change them.**

A ledger keeps a quick running total of each account's balance, so it doesn't have to re-add every
transaction from the beginning each time someone asks. But that total is only a copy kept for speed;
the real answer is the list of transactions itself. If the copy and the transactions ever disagree,
the copy is the one that's wrong — so something has to keep checking that the shortcut still matches
the truth.

And it isn't only balances. A ledger has lots of numbers that are supposed to match and could quietly
drift apart — what one party is owed against what the other owes on the same deal, the two halves of
the balance sheet, the money flowing into and out of a single transaction. So we ship a layer that
compares each pair every day and flags anything that doesn't line up: **ten checks in all.**

**You can't just subtract one total from another and expect zero.** Some money is legitimately
mid-flight — a payment that has been authorized but hasn't settled yet — so a raw difference is
nonzero even on a perfectly healthy book. Each check first accounts for the known reasons two numbers
can differ (a pending payment, a timing lag) and flags only what's left over — the same way you
reconcile a bank statement by ticking off the checks that haven't cleared yet before deciding
anything is actually wrong.

The checks are ordinary read-only database queries (`SELECT`s, and one `STABLE` function): no
trigger, no constraint, nothing on the path that writes the books.
[0004](/decisions/0004-where-logic-lives) removed the ledger-side drift views along with the PL/pgSQL
that fed them, and this is their declarative replacement rather than their reinstatement.

Most are **break lists** that must return zero rows. Two are **reconciliation statements** that always
return rows and must foot to zero. One is the summary — **ten checks at the merged baseline** (it grew
from the six at this ADR's writing as the close, cursor, equation and chart-lint checks joined; the
[database page](/database#what-the-schema-enforces-today) is the canonical count):

| | |
| --- | --- |
| `recon_balance_breaks` | The balance cache against the journal, per tenant, account and currency — in **six** classes: `balance_drift`, `seq_ahead`, `seq_behind`, `seq_gap`, `no_cache_row`, `no_entries` |
| `recon_entry_breaks` | Every entry no report can count, one row each, with the reason: `no_transaction`, `no_account`, `no_account_type` |
| `recon_transaction_breaks` | Debits ≠ credits **per currency**, plus single-leg and entryless transactions |
| `recon_scope_breaks` | The two sides of a cross-scope obligation, summed **per counterparty** (near = `tenant_id`, far = `owner_id`), per currency — so a third offsetting scope cannot cancel a real gap |
| `recon_journal_to_reports` | Journal against the **chart-presented posted population** (the statement functions' own population, not `trial_balance`), with `pending`, `superseded`, `out_of_window` and `orphan` named as reconciling items — `unexplained` must be zero |
| `recon_pending_bridge` | `available = posted + pending`, with the pending population named and aged, **excluding holds already resolved or reversed** |
| `recon_checkpoint_breaks` · `recon_close_breaks` · `recon_cursor_breaks` · `recon_equation_breaks` | The period checkpoint, close typing, cursor forgery, and the accounting equation — added from [0011](/decisions/0011-period-close-and-report-axes) and the seam-two fixes |
| `reconciliation` | **Ten** rows, one per check, `breaks = 0` on each. The whole operator interface |

**A break list and a statement are different objects and merging them loses the property that
matters.** A check that returns nothing because it was never run is indistinguishable from one that
passed, and this project has already paid for that: `TRUNCATE ledger_entries,
ledger_account_balances` left *"eleven transactions standing with zero entries, every currency
`balanced = t`, drift at zero rows … **silence read as assent**"*
([0004](/decisions/0004-where-logic-lives)). So `reconciliation` always returns its ten rows — six at
this ADR's writing: at integration the pending bridge left the summary (its rows are a legitimate
population, not breaks, once the cache was ruled to mean posted), and the checkpoint, close, cursor,
accounting-equation and `chart_lint`-error checks joined — and the two statements always return a row
per scope, whether or not there is anything to say.

### The four things that get decided along the way

**1 · Two balances, two names, one published identity — and the cache is ruled to mean POSTED.** The
question this settles is what the cache *means*: at this ADR's writing it counted every entry
(available), and the ruling is that **the cache means POSTED, the reports mean POSTED, and `available =
posted + pending` is a published identity `recon_pending_bridge` derives rather than stores.** Neither
number was wrong; nothing named either of them, and nothing let you get from one to the other.
Measured on this schema, one posted 100.00 and one pending 500.00: cache 600.00, statements 100.00,
`recon_pending_bridge` printing both with the 500.00 between them and footing.
**This ADR rules it** ([settled-framing decision on the cache](/roadmap#the-cache-means-posted)): the
cache means POSTED, so `recon_balance_breaks` compares `input`/`output` against the *posted* half of
the journal, and `recon_pending_bridge` **derives** available as posted plus the enumerated pending
population rather than asserting it — there is no `reconciles` boolean column, the bridge is a
statement that foots. The identity holds either way, which is why this ADR could name the numbers
before the ruling was folded in; the applied form is the ruling, not the open question.

**2 · The balance cache keeps all three jobs on one row.** It stays the write lock, the `account_seq`
counter and the cached balance. The objection on the open list is that the three *"all fail
together"*; the answer is that they do not have to be *detected* together. Each was reproduced with
the other two clean — `last_seq` forged forward with the balance exact, the balance forged with the
counter exact, a 48-wide hole with both exact — and each has its own class in one view. **Splitting
the row would cost the property that makes `account_seq` gapless at all**: the number is issued by
the same statement that advances the balance, under the lock it already holds, and
[0004](/decisions/0004-where-logic-lives) rejected a Postgres sequence precisely because a second
source of truth can disagree with the balance it orders. The read-side objection — that a hot
account's read never gets an index-only scan — is answered by measurement rather than by argument:
[spike 009](/spikes/009-where-the-balance-lives) clocked the cache read at **0.039 ms p50 against
0.043 ms** for the covering index on the append-only table, flat at every account size. **What is
being traded** is that the three failures share a blast radius even though they no longer share a
detector: one bad `UPDATE` can take out the lock, the counter and the balance in one statement, and
between two sweeps that is simply the answer customers get.

**3 · What an orphan is.** All three report views make the same three joins, so **an orphan is an
entry that fails one of them, for a reason other than its status** — and there are exactly three
classes, not a judgement call. A `pending` entry is not an orphan; it is a named reconciling item.
Every one of those joins is a foreign key, so the list is empty on the ordinary write path and
non-empty on the one that skips it: all **100** internal foreign-key triggers on the merged baseline ship `ENABLE ORIGIN`, and
`session_replication_role = 'replica'` — the logical-replication apply path, and what
`pg_restore --disable-triggers` sets — is how each case in the spike was made.

**4 · One proposed schema change, and it is small.** The cross-scope comparison needs to know which
account type holds the other side, and nothing in the chart says. `is_perimeter` says an account
mirrors an *external* balance; `counterparty_scope` says whether members of a split may be netted.
Deriving the pair from the `due_from_` / `due_to_` naming is the cheap answer and it is the one this
project's own rule refuses — a convention is not a constraint
([0007](/decisions/0007-schema-conventions-and-chart)):

```sql
ALTER TABLE account_types
    ADD COLUMN mirror_type text
        CONSTRAINT fk_types__mirror REFERENCES account_types (code)
        CONSTRAINT ck_types__mirror_not_self CHECK (mirror_type <> code);
```

Nullable, declared on one side of each pair, no symmetry enforcement — a `CHECK` cannot see the other
row and a trigger would need a justification it does not have. **Applied**: the column and the views
landed in `migrations/00001_baseline.sql` on 2026-08-27 under
[0003](/decisions/0003-migrations)'s editable-until-v0.1 exception
([roadmap question 1](/roadmap#the-baseline-is-editable-until-v01) is
answered), with three integration-time changes worth naming. **The pending question is ruled**: the
cache means POSTED, so `recon_balance_breaks` compares `input`/`output` against the posted half of
the journal while `last_seq` is checked against *all* entries — the counter issues `account_seq`
for pending entries too — and `recon_pending_bridge` *derives* available as posted plus the
enumerated pending population rather than asserting an identity view 1 already owns. **The views
run at stripe grain**, because [0013](/decisions/0013-write-path-contract) put the stripe below the
account and the lock, the counter and the cached number all live there. And **the family grew from [0011](/decisions/0011-period-close-and-report-axes) and the seam-two
fixes**: `recon_checkpoint_breaks` (the period checkpoint recomputed at its stored cursor — a
checkpoint nothing reconciles is the `balance_after` column with better manners), `recon_close_breaks`
(close typing), `recon_cursor_breaks` (a forged `xact_id`), `recon_equation_breaks` (the accounting
equation over the statement functions), and `close_disclosures` (entries backdated past a close —
legal, disclosed, never refused). The summary is **ten** checks, one row each, with `chart_lint`'s
errors as the tenth.

### When it runs, who runs it, and what happens on a nonzero row

**Once a day, at a cut-off, as an `openledger reconcile` subcommand — decided here, and the same shape
as `openledger migrate` ([0003](/decisions/0003-migrations)): a command an operator runs and schedules,
not a step that happens invisibly. Built 2026-08-28** — `crates/db/src/reconcile.rs` behind the
subcommand, one snapshot as the role below, ten zeros to exit 0 and the breaking checks named on
stderr at exit 1; the [service page](/service) carries the operator contract, and the daily
scheduling stays the operator's (a cron entry, a Kubernetes CronJob). The cadence is not invented here. The Federal Reserve's
*Commercial Bank Examination Manual* asks it as an internal-control question — §2320.4: *"Are the
above ledger or individual subsidiary accounts balanced to the general ledger on a **daily
basis**?"* — and the OCC puts *"balancing subsidiary records to general ledger control totals"*
inside the scope of audit itself (*Internal and External Audits*, M-AUD v1.0). The one comparable open-source project that ships this check at all, Envato's
`double_entry`, recommends *"a scheduled job, somewhere on the order of hourly to daily"*.

**Not on the read path, and not per write.** It is a scan: 410 ms at 100,000 entries and 6,334 ms at
1,000,000, serial — 15.5× for 10× the journal, because the book crosses `shared_buffers` in between.
Spike 009's rule for the per-account form is the same and blunter: *"This is a background sweep and
can never run on a read path."*

**In one `REPEATABLE READ READ ONLY` transaction**, because the sweep's views are many statements and under
`READ COMMITTED` each takes its own snapshot. Demonstrated: with a repair committing 2 s into the
sweep, the summary reported one break and the list enumerating it returned **zero rows** — an
operator paged by a count with nothing to look at. Under `REPEATABLE READ`, both said one. This is
safe in a way it is not on the write path: [0002](/decisions/0002-scaling)'s serialization failures
come from `ON CONFLICT DO UPDATE` under contention, and this transaction writes nothing. It takes
`ACCESS SHARE` and nothing else, so it cannot block a posting.

**By a role that cannot write what it checks.** The views grant to a new `openledger_recon`, not to
`openledger_app` — which holds `UPDATE` on `ledger_account_balances`, the number
`recon_balance_breaks` checks. [0004](/decisions/0004-where-logic-lives) learned this one level down:
validating `account_seq` against the cache failed because *"the application role holds `UPDATE` on
that table"*. The FDIC states the same rule for people: *"personnel that originate transactions
should not reconcile the entries to the general ledger"* (RMS Manual §4.2). **A grant is not a
constraint** — one `GRANT ALL` undoes it and it binds no superuser — and it is the same cheap outer
layer the baseline already gives the app role.

**On a nonzero row, the disposition depends on the class, and only one class is ever repaired
automatically.**

| class | source of truth | disposition |
| --- | --- | --- |
| `balance_drift` | the journal | Rebuild the row from `ledger_entries`, log both numbers, alert. Never a plug figure — the FDIC's manual names *"forced balancing"* as a control failure |
| `seq_ahead` | the journal | **Page.** Never repair: pulling `last_seq` back makes the next posting collide and pushing it forward is what caused the hole. Gaplessness is already lost |
| `seq_behind` | the journal | Alert. It fails closed on its own — verified, the next posting is refused by `uq_entries__account_seq` |
| `seq_gap`, `no_cache_row`, `no_entries` | the journal | Page. An entry is missing, was fabricated, or an account has no row to lock |
| orphan entries | — | **Not repairable.** The journal is append-only; the entry stays. Investigate the path that wrote it — a replica apply, a restore with triggers disabled |
| unbalanced / entryless transactions | — | **Not repairable.** A correction is a new transaction. Halt posting for that scope until it is understood |
| cross-scope gap | — | Escalate to whoever owns the two books. The fix is a posting, and somebody is owed money |
| pending items aging | — | Not a break until it is. `oldest_pending_effective_at` is in the view because a reconciling item that never clears is a break nobody has named |

**Automatic repair is deliberately narrow.** The cache is derived state and may be rebuilt;
**nothing that touches the journal is ever repaired by this layer**, because on an append-only table
a repair is a new transaction and a new transaction is a business decision.
[0006](/decisions/0006-time-and-as-of) already says the check *"should recompute rather than only
alarm, as Modern Treasury does"*, and their published sequence has three steps rather than two:
verify, **turn cache reads off for the drifted account**, then backfill with a runbook. **We take the
first and third and not the second, and it is a real gap rather than a simplification.** Degrading
one account's reads to a recompute needs a per-account flag the schema does not have and a read path
that consults it; adding one puts a branch on the hot path
([0002](/decisions/0002-scaling)'s serialization point) and a column whose wrong value is another
thing nothing checks. Until it exists, a drifted account keeps serving the wrong number until the
next sweep — which is the same window the "detection is periodic" cost below describes, and the
strongest argument for making the sweep cheap enough to run more than daily.

## The evidence

**Nothing compared any of these numbers, and several of the open list's rows are the same missing
object.** The cache against the journal, the journal against the reports, the two sides of a
cross-scope obligation, available against posted, debits against credits, and the counter against the
entries it ordered — one layer closes all six, and it closes them as reporting SQL because
[0004](/decisions/0004-where-logic-lives) already decided what the alternative would cost.

**The obvious version of the check is wrong, which is the finding that justifies designing this
rather than writing it.** The open list says of the journal-to-reports gap that *"three lines of SQL
would surface it"*. Three lines of SQL surface a **false positive on every healthy book carrying a
hold**: the raw difference between a journal `SUM` and a `trial_balance` `SUM` is nonzero for every
pending transaction, by design ([0007](/decisions/0007-schema-conventions-and-chart) rule 14).
Measured on a clean book with one pending withdrawal and nothing wrong: naive gap **50,000**,
unexplained **0**. And on a book carrying a 50,000.00 orphan pair *and* that same hold, the naive gap
is 5,050,000 with the two causes indistinguishable, while `unexplained_debits` is 0 and the orphan is
two rows with account ids in them. **A reconciliation is a statement with its reconciling items named,
not a subtraction** — which is what a bank reconciliation has always been, and the reason the FDIC's
examiners are told to look at *"the recurring use and aging of reconciling items"* rather than at a
difference.

**The comparison is only worth anything because the two sides have different mutability.** The
journal is append-only and the cache is not, so recomputing one from the other is an independent
check — and dropping the old running balance is precisely what made `recon_balance_breaks` the first
check on the cache that is independent *at all*. The number it replaces was not:
[spike 009](/spikes/009-where-the-balance-lives) dropped a per-entry running balance (`balance_after`)
that looked like a check on the cache but was computed *from* the cache, in the same transaction,
from the same locked row — *"two numbers with one source agree when they are both wrong."*

**Nobody in this field ships this, and the one project that does says why it has to.** Read at pinned
commits: **Formance** has no drift or repair mechanism at all — `grep -rni 'drift|repair'` over the
whole repository returns zero matches — while its repair migrations recompute unconditionally and
detect nothing, and `27-fix-invalid-pcv` is now a no-op notice because **the first repair migration
was itself buggy and had to be repaired**. The recompute path they would need already exists in their
code: point-in-time volume queries re-sum from `moves` while ordinary reads take the stored
aggregate, and **the two are never diffed**. **TigerBeetle** has the check and it is test-only — the
VOPR auditor and the Vortex workload rebuild account state from the request stream and panic on
mismatch — which is a legitimate answer there because there is no `UPDATE`, no `DELETE` and no
privilege to write an account row directly, so the population that corrupts a cache here does not
exist. **Envato's `double_entry`** ships it as a product feature, and its README is the sentence:
*"DoubleEntry tries really hard to make sure that stored account balances reflect the running
balances from the `double_entry_lines` table, but there is always the unlikely possibility that
something will go wrong."*

**And the word is already taken.** Every vendor's *reconciliation* means ledger-against-the-outside-
world — a bank statement, a processor file. What this ADR ships is the ledger against **itself**;
Modern Treasury calls that *cache drift* and Envato calls it *validation*. The external axis is where
`is_perimeter` attaches — *"mirrors exactly one external balance and must reconcile against it"* — and
it now **has** readers: `perimeter_attestations` stores what the third party said, `perimeter_drift`
compares the stored instant against it, and `chart_lint` names every perimeter account that has never
been attested ([0012](/decisions/0012-chart-governance)). The *feed* that supplies the attestations is
an integration this project does not ingest; the schema that reads the column is in place.

## What we considered

| | Why not |
| --- | --- |
| **A constraint or trigger that makes drift unreachable** | There is nothing to forbid: `ledger_account_balances` is *supposed* to be updated, that is what it is for. A deferred cross-row constraint cannot see the failures that matter either — [0004](/decisions/0004-where-logic-lives) showed a deferred `ck_txn__has_entries` cannot speak after a `TRUNCATE`, because it fires at the commit of a statement that *touched* a transaction |
| **One `drift` view returning one number** | The classes carry different dispositions — three of them are unrepairable, one fails closed on its own, and one is repaired automatically. A boolean loses all of that, and each class was reproduced with the others clean |
| **Run the check on the read path** | It is a scan of the journal. Spike 009: *"this is a background sweep and can never run on a read path"* |
| **Check per write, in the writer's transaction** | Turns a once-a-day linear scan into a per-posting cost on the one path [0002](/decisions/0002-scaling) is about, to catch a class of failure that arrives from outside that path anyway |
| **Materialized views, refreshed on a timer** | Stores a second copy of a number whose entire job is to check a copy. `REFRESH` takes `ACCESS EXCLUSIVE` unless `CONCURRENTLY`, which needs its own unique index and is slower, and a stale refresh is a break list that is empty for the wrong reason |
| **Compare the cache against a per-entry running balance** | It is the arrangement spike 009 removed. Not independent: one writer, one locked row, two numbers |
| **Auto-repair everything the sweep finds** | Three of the classes touch an append-only table where a repair is a new transaction and a business decision, and a `seq_ahead` repair destroys the evidence of the gap it caused. Modern Treasury's published answer repairs with a runbook and a human, not silently |
| **Derive the cross-scope pairs from the `due_from_`/`due_to_` naming** | A convention is not a constraint, which is [0007](/decisions/0007-schema-conventions-and-chart)'s own finding about Formance's `timestamp without time zone` columns held in UTC "by convention" — beside a migration named `fix-invalid-date-format` |
| **Reconcile against the external world instead** | The higher-value axis and a different one. It needs a counterparty statement to reconcile *to*, which this project does not ingest; `is_perimeter` is where it attaches when it exists |
| **Leave it to operators to write their own queries** | What pgledger and Formance do. It makes every adopter re-derive what an orphan is and what the reconciling items are, and the spike's whole finding is that the obvious version of that query is wrong |

## What it costs

| | |
| --- | --- |
| **A daily linear scan, growing with history** | 410 ms at 100,000 entries, 6,334 ms at 1,000,000, serial, medians on a shared machine — 15.5× for 10× the data, because the journal crosses `shared_buffers` between the two sizes. For scale against the project's own linearity figures: [0006](/decisions/0006-time-and-as-of) puts the effective-axis aggregate at *"roughly 0.10 µs per entry"* and **105.91 ms** for a 1M-entry account, and spike 009's per-account recompute at 57.5 ms; this reads every entry six times over and lands at ~6 µs/entry. Budget it as linear and re-measure at your size; **the ratio is the finding, and here even the ratio moves** |
| **It pins the transaction horizon while it runs** | One snapshot for the whole family of views means one `backend_xmin` for the whole sweep, and on this schema that is expensive twice over: it holds back the scheduled `VACUUM` [spike 009](/spikes/009-where-the-balance-lives) says `ledger_account_balances` must have and autovacuum will never give it, and it pins [0006](/decisions/0006-time-and-as-of)'s as-of watermark, which is defined off `pg_snapshot_xmin`. **A deployment large enough for this to matter must bound the sweep per tenant rather than run it as one transaction** |
| **…and the horizon the cursor check reads is the CLUSTER's, not this book's** | `recon_cursor_breaks` flags an entry `above_horizon` when its `xact_id` sits above `pg_snapshot_xmin(pg_current_snapshot())` — and that horizon is the whole server's, as `report_cursor()`'s own comment in the baseline states: one concurrent transaction *anywhere*, another database included, transiently pins it below entries this book has already committed, so a healthy book reports breaks until that writer commits. The sweep therefore **assumes quiescence relative to the horizon**. The e2e suite makes the assumption explicit with a bounded wait for the horizon to retire the book's newest entry before reading the summary (`crates/e2e/tests/e2e/support/book.rs` — its tests run concurrent sibling books on one cluster, exactly the shape that trips this); a real daily sweep at low-traffic hours has the same property without stating it. A forged far-future `xact_id` outlives any such wait and still flags |
| **Detection is periodic, so the window is real** | Between two sweeps a forged cache is simply the answer customers get. This buys nothing at all against a caller who is fast |
| **A drift view detects disagreement, never fabrication** | [0004](/decisions/0004-where-logic-lives)'s sentence, and it applies to all ten. A caller holding `INSERT` on `ledger_entries` and `UPDATE` on `ledger_account_balances` — exactly what the baseline grants — can write an entry *and* advance the cache to match, and every view stays empty. What append-only buys is that the fabrication must be **added** rather than hidden: the entry is in the list forever. That is a weaker guarantee and it is the honest one |
| **The cross-scope view is grouped by counterparty, not deployment-wide** | An earlier form summed the pair across all scopes, so a third scope holding an offsetting 40,000.00 made a real 40,000.00 gap sum to zero and the view went silent. The fix (A9) is the **`GROUP BY`**: `recon_scope_breaks` now groups the pair sum by counterparty — near = `tenant_id`, far = `owner_id` — so an offset can only cancel a gap between the *same* two parties, which is the only offset accounting permits. The mechanism was the grouping, not `uq_accounts__house` (which no longer nets a house account across counterparties — `ck_accounts__per_shard_is_owned` forces `due_to_tenants` to be owned per scope). Whether a `per_shard` line prints net or gross on the face is the [settled per-shard/counterparty framing decision](/roadmap#per-shard-lines-and-the-counterparty-axis) |
| **...and cannot tell a timing difference from a loss** | The operator posting its side of an obligation tomorrow is indistinguishable from never posting it. A settlement lag on the pair would fix that and is not designed |
| **A mirror pair nobody declares is caught by a heuristic, not a constraint — and we decline to change that** | `recon_scope_breaks` reconciles a *declared* pair, and `chart_lint` errors (`mirror_same_side`) on a declared pair pointing at one side; but a pair nobody declares is caught only by `chart_lint`'s heuristic **warning** (`mirror_undeclared`), never by a key (A9). This is a chosen limitation, not an open question: the symmetry is one a `CHECK` cannot see across the two rows, and we decline to enforce it with a trigger, which would need a justification it does not have. |
| **The reportable window is a hardcoded sanity band, not configuration — by choice** | `recon_journal_to_reports` buckets an entry as `out_of_window` when its `effective_at` falls outside `[1900-01-01, now() + 1 year)` (A17), so a fat-fingered year-2226 date surfaces as a reconciling item rather than silently reported. We leave that band **hardcoded** rather than add a config table — tunable by editing the view until a deployment actually needs a different band, at which point a `CHECK` or a settings row is the change. A stated limitation, chosen over configurable correctness. |
| **A family of reconciliation views (ten checks at the merged baseline, six at this ADR's writing), three roles and one column more to maintain** | And the views encode the shape of `trial_balance`'s joins, so a change to that view is a change here. That coupling is deliberate — `recon_journal_to_reports` compares its own classification against what the shipped view *actually* returns, so a report that grows a filter this layer does not know about shows up as `unexplained` rather than as a silently dropped sub-book |
| **The `input`/`output` mapping had to be decided to write any of this** | Nothing in `migrations/`, `site/content/` or the glossary says which entry direction `ledger_account_balances.input` accumulates. The only place in the tree that decides it is a spike harness (`spikes/003-throughput-ceiling/bench_schema.sql`), which makes `input` the debits. These views adopt that and are the first object in the repository that makes it falsifiable: under the other reading, every credit-normal account reports drift on its first entry |
| **The parallel plan wants shared memory the default container does not have** | `SELECT count(*) FROM reconciliation` at 1M entries failed 3/3 with *"could not resize shared memory segment … No space left on device"* under Docker's 64 MB `/dev/shm` default. `docker-compose.yml` now sets `shm_size: 1gb` for exactly this, with the failure quoted in a comment beside it; the cost is that a deployment that does not carry that setting forward hits the same wall (or must run the sweep serially, which succeeds every time) |
| **It closes M2's stated hole and does not close M3's** | The roadmap says M2 *"has to build the view it wants to assert on, or say it is not checking drift"*. This is that view. It is not the writer, and [0005](/decisions/0005-event-log-and-write-path)'s posting type is still what makes an unbalanced transaction unrepresentable — `recon_transaction_breaks` reports one, it does not refuse one |
