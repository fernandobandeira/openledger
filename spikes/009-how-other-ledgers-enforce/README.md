# Spike 009 — do real ledgers use triggers, and where does the balance invariant live?

**Status:** closed

**Question.** [ADR-0012](../../docs/decisions/0012-where-logic-lives.md) removed 25 of 27 triggers on
the grounds that triggers are a maintainability problem. Is that true of real ledgers, or folklore?

**Method.** Nine open-source SQL and ORM-backed ledgers, read from source at a pinned commit. Where
possible the schema was applied to a throwaway PostgreSQL and the catalog queried directly, rather
than trusting the migration text.

---

## The answer, in two parts

**1. Triggers are widely used, and the anti-trigger doctrine has no canonical citation.** Three of
the nine ship them in production: **Formance runs 8** per bucket schema (verified by applying all 54
migrations and querying `pg_trigger`), **Blnk runs 8** including a `BEFORE UPDATE` immutability guard
on its journal, and **Midaz** protects its audit tables with `BEFORE TRUNCATE` triggers, citing
SOX/GLBA by name. The ThoughtWorks Technology Radar has no entry against them; the PostgreSQL wiki's
*Don't Do This* page says *"Don't use rules. If you think you want to, **use a trigger instead**."*

**2. But not one of the nine enforces "debits equal credits" with a trigger or a constraint.** Every
one makes it either structurally unrepresentable or checks it in application code. That is the real
line, and it is the one [ADR-0013](../../docs/decisions/0013-the-write-path.md) now follows.

| | Triggers | Balance invariant lives | Append-only mechanism |
| --- | --- | --- | --- |
| **Formance** | **8** | Go type only — 0 constraints, 0 FKs | **none**; `moves` is UPDATE-heavy; 0 grants in repo |
| **pgledger** | **0** | Unrepresentable — it is the *table* | none; 0 grants, direct INSERT possible |
| **Blnk** | **8** | Structural (single transfer row) | **trigger**, `BEFORE UPDATE` only — DELETE unguarded |
| **Midaz** | 0 in the ledger, **3 + 4 rules** in audit | Go, `validations.go` | none in the ledger (`deleted_at`!); rules + `BEFORE TRUNCATE` in audit |
| **envato `double_entry`** | 0 | Ruby — **plus a reconciliation sweep and an auto-fixer** | none |
| **django-ledger** | 0 | Python, at post time | none |
| **Medici** | n/a (Mongo) | JS, **against a rounded float** | `voided` flag |
| **python-accounting** | 0 DB triggers — an **ORM `after_insert` listener** instead | Both sides on one row | hash chain in app code |
| **Beancount / hledger / ledger** | n/a (text) | Parser — and it is *constitutive* | none |

---

## The three findings worth keeping

### Formance rebuilt a trigger set after demolishing one, and ships it on by default

Verified at `335bd03c` by applying all 54 migrations and querying the catalog: `set_log_hash`,
`set_effective_volumes`, `update_effective_volumes`, four metadata-history triggers, and
`set_transaction_updated_at`. Seven are created **per ledger** from Go, each feature-gated — and
`DefaultFeatures` sets **every gate to `SYNC`**. An operator running `MinimalFeatureSet` gets one.

**This corrects our own [spike 001](../001-formance/README.md)**, which concluded the trigger cascade
"was ripped out and moved into Go." Migration 37 did drop the v1 cascade; Formance then built a
smaller set and kept it.

What they kept has a shape: **assignment and derivation on insert, for things that must be true of
every row no matter which code path wrote it, and that no key can express.** What they removed was
orchestration — `handle_log()` dispatching on event type — and derivation-with-backfill.

And the cleanest precedent for our two foreign keys: migration 11 created
`enforce_reference_uniqueness`, a `CREATE CONSTRAINT TRIGGER … DEFERRABLE INITIALLY DEFERRED` that
took an advisory lock and scanned for duplicates. **Migration 15 deleted it and replaced it with a
partial unique index.** They wrote the deferred constraint trigger first, and then took it out.

### Blnk's immutability trigger: the maintainability failure mode, demonstrated

Their guard enumerates protected columns explicitly, so every column added later is unguarded by
default. Tested against their own applied schema:

```
UPDATE ... SET amount = 999             refused
UPDATE ... SET precise_amount = 999     refused
UPDATE ... SET parent_transaction = ... ALLOWED
UPDATE ... SET effective_date = ...     ALLOWED
UPDATE ... SET chain_hash = ...         ALLOWED
DELETE FROM blnk.transactions           ALLOWED   -- there is no DELETE guard at all
```

`precise_amount` — **the column that actually carries the money** — was added 2024-04-09, the
immutability trigger shipped 2025-03-16 without it, and it reached the guard list on 2026-06-11, in a
migration whose stated purpose was adding a hash chain. **The money column was unprotected for 26
months.**

That is the strongest argument in the survey against triggers, and read carefully it is an argument
for **column-agnostic** guards, not against guards. Our `refuse_mutation()` refuses every `UPDATE`
and every `DELETE` and names no columns, so it cannot rot this way.

### Midaz independently invented our TRUNCATE guard, with a regulation attached

```sql
-- Immutability rules: prevent UPDATE and DELETE on transaction_validations
-- Required for SOX/GLBA compliance - audit records must never be modified
CREATE OR REPLACE RULE prevent_transaction_validation_update AS
    ON UPDATE TO transaction_validations DO INSTEAD NOTHING;
CREATE OR REPLACE TRIGGER prevent_transaction_validation_truncate_trigger
    BEFORE TRUNCATE ON transaction_validations
    FOR EACH STATEMENT EXECUTE FUNCTION prevent_truncate();
```

Someone else hit "nothing declarative can stop a `TRUNCATE`" and reached the same answer.

**One difference matters, and we are on the right side of it.** Midaz uses
`RULE … DO INSTEAD NOTHING` for UPDATE and DELETE, which **silently discards** the write — a caller
gets `UPDATE 0` and no error. Ours raises. Silence read as assent is the exact failure mode
[ADR-0011](../../docs/decisions/0011-what-the-database-enforces.md) is about.

---

## The negative result

**No established open-source ledger enforces debits-equal-credits in the database.** GitHub code
search for `"CREATE CONSTRAINT TRIGGER" "DEFERRABLE INITIALLY DEFERRED" ledger language:sql` returns
the pattern in the wild — including files named `defer_journal_balance_check_to_commit.sql` — but
every hit was a small or unknown repository. Caveat: code search covers only indexed public repos.

## Two corrections to our own documents

- **Spike 001 says Formance's README calls "debits always equal credits" marketing.** No such claim
  appears in the README at `335bd03c`. Struck.
- **Spike 001 says "five of nine `NOT VALID`, four validated."** True at an earlier commit. Today the
  census is **4 CHECK constraints, all `NOT VALID`, and zero foreign keys** — migration 40's
  `ADD NOT VALID → VALIDATE → SET NOT NULL → DROP` drops the four it validated.

## What could not be verified

Whether Formance's per-ledger triggers exist in any given production deployment (8 is the default,
1 under `MinimalFeatureSet`). Formance migrations 19 and 28 were inspected but not executed — they
are DML-only repairs and create no objects. The replay used PostgreSQL 16, not a confirmed production
target. Whether Blnk's application actually issues the DELETEs its schema permits. Whether Midaz ever
soft-deletes a posted transaction. Whether any of these has a period close — only django-ledger's
`ClosingEntryModel` surfaced, and it was not investigated.
