//! The schema snapshot test — ADR-0007 §2, the charge ADR-0009 widened.
//!
//! Migrate an empty scratch database with the compiled binary, dump the
//! catalog state the migrations produced as one deterministic text file, and
//! diff it against the committed `schema/snapshot.txt`. The contract is the
//! same as `crates/api/tests/spec.rs` holds over `openapi.json`: the
//! committed file is written by this test itself under an explicit opt-in
//! (`make schema-snapshot`), so a normal run can only ever FAIL on drift,
//! never paper over it by rewriting the file it was about to compare.
//!
//! Why it lives HERE and not in crates/db: this test needs a real migrated
//! PostgreSQL, and this suite is where databases come from — the scratch-
//! database registry, the migrate mutex, and the no-DATABASE_URL container
//! fallback (`support::postgres`). crates/db's own tests are deliberately
//! database-free (migrate.rs states that rule). It dumps its OWN scratch
//! database rather than a shared one because the snapshot is of the migrated
//! baseline alone: `schema/chart.sql` is seed data owned by no migration
//! (ADR-0007 §9), and a chart-seeded database would put example rows into
//! the `account_types` section below.
//!
//! What the dump is FOR — the owner-accident DDL class ADR-0009 accepts as
//! out-of-model and names this test the only backstop of: a disabled
//! trigger or event trigger, a dropped policy, `DISABLE ROW LEVEL
//! SECURITY`, a replaced view body, a dropped constraint or index, an
//! `UPDATE account_types SET is_perimeter …`. None of those fail a query;
//! all of them change a line here.

use std::collections::BTreeMap;

use sqlx::PgPool;
use sqlx::postgres::PgPoolOptions;

use crate::support::TestResult;
use crate::support::postgres;

/// The committed snapshot. It lives in `schema/` beside `chart.sql` for the
/// same reason the migrations live at the repository root (crates/db's
/// lib.rs states it): it is adopter-facing — the reviewable statement of
/// what the migrations put into a database, and the reference an operator
/// can diff a production catalog against — not an implementation detail of
/// this suite.
const SNAPSHOT_PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../schema/snapshot.txt");

const REGENERATE: &str = "regenerate it with `make schema-snapshot` (OPENLEDGER_WRITE_SCHEMA_SNAPSHOT=1) \
     and commit the diff — but only if the schema change itself is intended: \
     this file is the guard against schema drift, ADR-0007 §2";

/// The dump's preamble, part of the compared bytes. It states what the file
/// is and what is deliberately not in it, so a reader of the snapshot needs
/// neither this test's source nor the ADR to know what absence means.
const HEADER: &str = "\
OpenLedger schema snapshot — the catalog state `openledger migrate` produces on an
empty PostgreSQL 18 database, dumped as deterministic text and diffed in CI against
this committed copy (ADR-0007 §2; the charge ADR-0009 widened for the owner-accident
DDL class). Regenerate with `make schema-snapshot`; a normal test run only compares.

Deliberately NOT in this dump, so the diff stays meaningful:
- OIDs, and anything derived from them: the internal foreign-key trigger names
  (RI_ConstraintTrigger_<oid>) differ per database, so those triggers appear
  aggregated per constraint, as a count and enablement states (ADR-0009 §A).
- Owner and grantor names: the migrating role differs per environment (compose,
  CI's service container, the e2e testcontainer). ACL entries are filtered to
  the migration-created openledger_* roles and PUBLIC.
- Table data, with one charged exception: account_types.is_perimeter/mirror_type
  (ADR-0007 §2). The section is empty on the baseline because the example chart
  is seed data owned by no migration (ADR-0007 §9) — a deployment can run the
  same dump against its seeded database.
- _sqlx_migrations rows (timestamps, execution times); its catalog shape IS here.
- Extension versions and extension-owned objects (btree_gist's ~200 support
  functions), which track the server image, not the migrations.
- Statistics, sizes, vacuum state — runtime, not schema.
Formatting note: pg_get_*def output is PostgreSQL-major-version text (18, the
pinned image everywhere this runs); every ORDER BY collates in \"C\".
";

/// Every section is one SQL statement returning ordered text rows, so the
/// dump is the concatenation of catalog queries and nothing computed here
/// can drift from what the database says. Each query ends in ORDER BY over
/// its whole visible key, COLLATE "C" on text, and never selects an OID.
const SECTIONS: [(&str, &str); 19] = [
    (
        "extensions",
        r#"SELECT extname FROM pg_extension ORDER BY extname COLLATE "C""#,
    ),
    (
        "enum types",
        r#"SELECT t.typname || ': ' || string_agg(e.enumlabel, ', ' ORDER BY e.enumsortorder)
           FROM pg_type t
           JOIN pg_namespace n ON n.oid = t.typnamespace
           JOIN pg_enum e ON e.enumtypid = t.oid
           WHERE n.nspname = 'public'
           GROUP BY t.typname
           ORDER BY t.typname COLLATE "C""#,
    ),
    (
        // relkind r table, v view, m matview, S sequence, p partitioned;
        // relpersistence p permanent, u UNLOGGED (an `ALTER TABLE SET
        // UNLOGGED` on the journal loses it on a crash — that flip is one
        // catalog letter here). relrowsecurity/relforcerowsecurity are the
        // `DISABLE ROW LEVEL SECURITY` backstop; reloptions is where a
        // view's security_invoker lives (ADR-0013).
        "relations (kind, persistence, row security, reloptions)",
        r#"SELECT c.relkind::text || ' ' || c.relname
                  || ' persistence=' || c.relpersistence::text
                  || ' rowsecurity=' || c.relrowsecurity
                  || ' forcerowsecurity=' || c.relforcerowsecurity
                  || ' options=[' || coalesce(array_to_string(c.reloptions, ', '), '') || ']'
           FROM pg_class c
           JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
           ORDER BY c.relname COLLATE "C""#,
    ),
    (
        // attnum order, not name order: column position is real schema (a
        // SELECT * reads it), and the baseline is frozen so there are no
        // dropped-column gaps to make it unstable.
        "columns",
        r#"SELECT c.relname || '.' || a.attname || ': ' || format_type(a.atttypid, a.atttypmod)
                  || CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END
                  || CASE WHEN d.adbin IS NULL THEN ''
                          WHEN a.attgenerated::text = 's'
                              THEN ' GENERATED ALWAYS AS ' || pg_get_expr(d.adbin, d.adrelid) || ' STORED'
                          ELSE ' DEFAULT ' || pg_get_expr(d.adbin, d.adrelid)
                     END
           FROM pg_attribute a
           JOIN pg_class c ON c.oid = a.attrelid
           JOIN pg_namespace n ON n.oid = c.relnamespace
           LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
           WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm')
             AND a.attnum > 0 AND NOT a.attisdropped
           ORDER BY c.relname COLLATE "C", a.attnum"#,
    ),
    (
        // The FULL pg_constraint set, names and definitions (a DROP
        // CONSTRAINT shows as a missing line) — including the PG18
        // server-generated <table>_<column>_not_null rows, whose names are
        // derived from table and column, never from an OID (ADR-0007).
        "constraints (the full pg_constraint set)",
        r#"SELECT coalesce(t.relname || ' ', '') || con.conname || ': '
                  || pg_get_constraintdef(con.oid)
                  || CASE WHEN con.convalidated THEN '' ELSE ' -- NOT VALID' END
           FROM pg_constraint con
           JOIN pg_namespace n ON n.oid = con.connamespace
           LEFT JOIN pg_class t ON t.oid = con.conrelid
           WHERE n.nspname = 'public'
           ORDER BY coalesce(t.relname, '') COLLATE "C", con.conname COLLATE "C""#,
    ),
    (
        // Charged separately by ADR-0007 §2 and convention 5: a NOT VALID
        // constraint that survives its own migration is a lie in the
        // schema, so this section existing as "(none)" is the assertion.
        "constraints marked NOT VALID (must stay empty, ADR-0007 §5)",
        r#"SELECT t.relname || ' ' || con.conname
           FROM pg_constraint con
           JOIN pg_class t ON t.oid = con.conrelid
           JOIN pg_namespace n ON n.oid = con.connamespace
           WHERE n.nspname = 'public' AND NOT con.convalidated
           ORDER BY t.relname COLLATE "C", con.conname COLLATE "C""#,
    ),
    (
        // indisvalid/indisready catch the half-built residue of a failed
        // CREATE INDEX CONCURRENTLY, which pg_get_indexdef alone would
        // print as a healthy index.
        "indexes",
        r#"SELECT pg_get_indexdef(x.indexrelid)
                  || ' valid=' || x.indisvalid || ' ready=' || x.indisready
           FROM pg_index x
           JOIN pg_class i ON i.oid = x.indexrelid
           JOIN pg_class t ON t.oid = x.indrelid
           JOIN pg_namespace n ON n.oid = t.relnamespace
           WHERE n.nspname = 'public'
           ORDER BY t.relname COLLATE "C", i.relname COLLATE "C""#,
    ),
    (
        // tgenabled is the restore-path column: `pg_restore
        // --disable-triggers` leaves ENABLE ALWAYS ('A') downgraded to
        // ENABLE ORIGIN ('O'), a two-character diff nothing else reads
        // (ADR-0009 §B). 'D' is disabled.
        "triggers (tgenabled: A always, O origin, R replica, D disabled)",
        r#"SELECT t.relname || ' ' || g.tgname || ' enabled=' || g.tgenabled::text
                  || ': ' || pg_get_triggerdef(g.oid)
           FROM pg_trigger g
           JOIN pg_class t ON t.oid = g.tgrelid
           JOIN pg_namespace n ON n.oid = t.relnamespace
           WHERE n.nspname = 'public' AND NOT g.tgisinternal
           ORDER BY t.relname COLLATE "C", g.tgname COLLATE "C""#,
    ),
    (
        // The internal RI triggers carry OID-derived names, so they are
        // keyed by (table, constraint) instead — which still catches an
        // `ALTER TABLE ... DISABLE TRIGGER ALL` flipping them to 'D'.
        "foreign-key internal triggers (per constraint: count and enablement)",
        r#"SELECT t.relname || ' ' || con.conname || ': ' || count(*) || ' enabled='
                  || string_agg(g.tgenabled::text, '' ORDER BY g.tgenabled::text)
           FROM pg_trigger g
           JOIN pg_class t ON t.oid = g.tgrelid
           JOIN pg_namespace n ON n.oid = t.relnamespace
           JOIN pg_constraint con ON con.oid = g.tgconstraint
           WHERE n.nspname = 'public' AND g.tgisinternal
           GROUP BY t.relname, con.conname
           ORDER BY t.relname COLLATE "C", con.conname COLLATE "C""#,
    ),
    (
        "event triggers (evtenabled: A always, O origin, R replica, D disabled)",
        r#"SELECT e.evtname || ' on ' || e.evtevent || ' enabled=' || e.evtenabled::text
                  || ' function=' || p.proname
                  || ' tags=[' || coalesce(array_to_string(e.evttags, ', '), '') || ']'
           FROM pg_event_trigger e
           JOIN pg_proc p ON p.oid = e.evtfoid
           ORDER BY e.evtname COLLATE "C""#,
    ),
    (
        // Full policy definitions: kind, command, roles, USING and WITH
        // CHECK expressions. polroles = {0} means PUBLIC.
        "row-level security policies",
        r#"SELECT t.relname || ' ' || pol.polname
                  || CASE WHEN pol.polpermissive THEN ' permissive' ELSE ' restrictive' END
                  || ' cmd=' || pol.polcmd::text
                  || ' roles=[' || coalesce(
                         (SELECT string_agg(r.rolname, ', ' ORDER BY r.rolname COLLATE "C")
                          FROM pg_roles r WHERE r.oid = ANY (pol.polroles)), 'PUBLIC') || ']'
                  || ' using=(' || coalesce(pg_get_expr(pol.polqual, pol.polrelid), '') || ')'
                  || ' check=(' || coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), '') || ')'
           FROM pg_policy pol
           JOIN pg_class t ON t.oid = pol.polrelid
           JOIN pg_namespace n ON n.oid = t.relnamespace
           WHERE n.nspname = 'public'
           ORDER BY t.relname COLLATE "C", pol.polname COLLATE "C""#,
    ),
    (
        // Every view's body: a `CREATE OR REPLACE VIEW reconciliation AS
        // SELECT 0` and a RENAME/SET SCHEMA moving a base table both land
        // here, and nowhere else (ADR-0009).
        "view definitions (pg_get_viewdef, every view)",
        r#"SELECT c.relname || ':' || chr(10) || pg_get_viewdef(c.oid, true)
           FROM pg_class c
           JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'public' AND c.relkind IN ('v', 'm')
           ORDER BY c.relname COLLATE "C""#,
    ),
    (
        // Function bodies: a CREATE OR REPLACE FUNCTION gutting
        // refuse_mutation() or a report function is the same accident class
        // as a replaced view — no charged column, same backstop. Extension-
        // owned functions (btree_gist's support set) are excluded above.
        "functions (pg_get_functiondef, migration-owned only)",
        r#"SELECT pg_get_functiondef(p.oid)
           FROM pg_proc p
           JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.prokind = 'f'
             AND NOT EXISTS (SELECT 1 FROM pg_depend dep
                             WHERE dep.classid = 'pg_proc'::regclass
                               AND dep.objid = p.oid AND dep.deptype = 'e')
           ORDER BY p.proname COLLATE "C",
                    pg_get_function_identity_arguments(p.oid) COLLATE "C""#,
    ),
    (
        // The migration-created roles and their attributes — rolbypassrls
        // is the one ADR-0013 §5 refuses to ever set. Cluster-wide roles
        // outside openledger_* (the e2e login fixtures) are not the
        // migrations' and are excluded.
        "roles (openledger_*)",
        r#"SELECT rolname || ' login=' || rolcanlogin || ' super=' || rolsuper
                  || ' inherit=' || rolinherit || ' createrole=' || rolcreaterole
                  || ' createdb=' || rolcreatedb || ' replication=' || rolreplication
                  || ' bypassrls=' || rolbypassrls
           FROM pg_roles
           WHERE rolname LIKE 'openledger\_%'
           ORDER BY rolname COLLATE "C""#,
    ),
    (
        // The schema ACL is where `REVOKE CREATE ON SCHEMA public FROM
        // PUBLIC` shows — as the absence of a CREATE line.
        "schema acl (public)",
        r#"SELECT coalesce(r.rolname, 'PUBLIC') || ' ' || x.privilege_type
           FROM pg_namespace n
           CROSS JOIN LATERAL aclexplode(n.nspacl) x
           LEFT JOIN pg_roles r ON r.oid = x.grantee
           WHERE n.nspname = 'public'
           ORDER BY coalesce(r.rolname, 'PUBLIC') COLLATE "C", x.privilege_type COLLATE "C""#,
    ),
    (
        // GRANT lists per relation, filtered to the migration-created
        // roles: the owner's implicit entries would name whichever role
        // migrated this particular database. A widened grant (UPDATE on
        // the journal to the app role) is a new line here; the baseline's
        // explicit REVOKEs show as those lines' absence.
        "relation grants (to openledger_* and PUBLIC)",
        r#"SELECT c.relname || ': ' || g.grantee_name || ' ' || g.privilege_type
           FROM pg_class c
           JOIN pg_namespace n ON n.oid = c.relnamespace
           CROSS JOIN LATERAL (
               SELECT coalesce(r.rolname, 'PUBLIC') AS grantee_name, x.privilege_type
               FROM aclexplode(c.relacl) x
               LEFT JOIN pg_roles r ON r.oid = x.grantee
           ) g
           WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
             AND (g.grantee_name LIKE 'openledger\_%' OR g.grantee_name = 'PUBLIC')
           ORDER BY c.relname COLLATE "C", g.grantee_name COLLATE "C",
                    g.privilege_type COLLATE "C""#,
    ),
    (
        // Column-level grants — the writer's INSERT column lists and the
        // balance cache's UPDATE (input, output, last_seq, updated_at),
        // the declarative half of ADR-0009 §E's owner-column freeze.
        "column grants (to openledger_* and PUBLIC)",
        r#"SELECT c.relname || '.' || a.attname || ': '
                  || coalesce(r.rolname, 'PUBLIC') || ' ' || x.privilege_type
           FROM pg_class c
           JOIN pg_namespace n ON n.oid = c.relnamespace
           JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
           CROSS JOIN LATERAL aclexplode(a.attacl) x
           LEFT JOIN pg_roles r ON r.oid = x.grantee
           WHERE n.nspname = 'public'
             AND (r.rolname LIKE 'openledger\_%' OR r.rolname IS NULL)
           ORDER BY c.relname COLLATE "C", a.attname COLLATE "C",
                    coalesce(r.rolname, 'PUBLIC') COLLATE "C", x.privilege_type COLLATE "C""#,
    ),
    (
        // The one charged DATA exception (ADR-0007 §2): an identity UPDATE
        // on either column silences a perimeter or mirror check. Empty on
        // the baseline — the chart is seed data (header).
        "account_types.is_perimeter / mirror_type (ADR-0007 §2's charged data)",
        r#"SELECT code || ' is_perimeter=' || is_perimeter
                  || ' mirror_type=' || coalesce(mirror_type, '(none)')
           FROM account_types
           ORDER BY code COLLATE "C""#,
    ),
    (
        // Convention 16: the catalog documents itself, and a removed or
        // drifted comment fails the build like any other schema change.
        // pg_describe_object names each commented object without its OID.
        "comments (pg_description)",
        r#"SELECT pg_describe_object(d.classoid, d.objoid, d.objsubid) || ' = ' || d.description
           FROM pg_description d
           WHERE (d.classoid = 'pg_class'::regclass AND d.objoid IN
                      (SELECT c.oid FROM pg_class c
                       JOIN pg_namespace n ON n.oid = c.relnamespace
                       WHERE n.nspname = 'public'))
              OR (d.classoid = 'pg_proc'::regclass AND d.objoid IN
                      (SELECT p.oid FROM pg_proc p
                       JOIN pg_namespace n ON n.oid = p.pronamespace
                       WHERE n.nspname = 'public'
                         AND NOT EXISTS (SELECT 1 FROM pg_depend dep
                                         WHERE dep.classid = 'pg_proc'::regclass
                                           AND dep.objid = p.oid AND dep.deptype = 'e')))
              OR (d.classoid = 'pg_type'::regclass AND d.objoid IN
                      (SELECT t.oid FROM pg_type t
                       JOIN pg_namespace n ON n.oid = t.typnamespace
                       WHERE n.nspname = 'public'
                         AND NOT EXISTS (SELECT 1 FROM pg_depend dep
                                         WHERE dep.classid = 'pg_type'::regclass
                                           AND dep.objid = t.oid AND dep.deptype = 'e')))
              OR (d.classoid = 'pg_constraint'::regclass AND d.objoid IN
                      (SELECT con.oid FROM pg_constraint con
                       JOIN pg_namespace n ON n.oid = con.connamespace
                       WHERE n.nspname = 'public'))
              OR d.classoid IN ('pg_trigger'::regclass, 'pg_policy'::regclass,
                                'pg_event_trigger'::regclass)
           ORDER BY pg_describe_object(d.classoid, d.objoid, d.objsubid) COLLATE "C""#,
    ),
];

#[tokio::test]
async fn the_committed_snapshot_matches_the_migrated_schema() -> TestResult {
    let db_url = postgres::create_scratch_db("schema_snapshot").await?;
    postgres::migrate(&db_url)?;
    let pool = PgPoolOptions::new()
        .max_connections(2)
        .connect(&db_url)
        .await?;

    // Deterministic or the diff means nothing: dump twice, compare —
    // the same self-check the OpenAPI snapshot runs on its emission.
    let generated = dump_catalog_state(&pool).await?;
    assert_eq!(
        generated,
        dump_catalog_state(&pool).await?,
        "the catalog dump is not deterministic — two dumps of one database disagree"
    );

    if std::env::var_os("OPENLEDGER_WRITE_SCHEMA_SNAPSHOT").is_some() {
        std::fs::write(SNAPSHOT_PATH, &generated)?;
        return Ok(());
    }

    let committed = std::fs::read_to_string(SNAPSHOT_PATH)
        .map_err(|e| format!("could not read {SNAPSHOT_PATH}: {e} — {REGENERATE}"))?;
    if committed != generated {
        return Err(format!(
            "schema/snapshot.txt no longer matches what the migrations produce.\n\
             If this drift is an intended schema change, {REGENERATE}.\n\
             The drift, [-committed +migrated]:\n{}",
            line_drift(&committed, &generated)
        )
        .into());
    }
    Ok(())
}

async fn dump_catalog_state(pool: &PgPool) -> Result<String, Box<dyn std::error::Error>> {
    let mut out = String::from(HEADER);
    for (title, sql) in SECTIONS {
        out.push_str("\n== ");
        out.push_str(title);
        out.push_str(" ==\n");
        let rows: Vec<String> = sqlx::query_scalar(sql).fetch_all(pool).await?;
        if rows.is_empty() {
            out.push_str("(none)\n");
        }
        for row in rows {
            out.push_str(&row);
            out.push('\n');
        }
    }
    Ok(out)
}

/// The lines only one side has, as `-`/`+` — readable where dumping two
/// multi-thousand-line strings whole is not. Deterministic ordering makes a
/// set-with-counts diff faithful: a moved line would show as one `-` and one
/// `+`, but ordered emission means lines only ever appear, disappear, or
/// change.
fn line_drift(committed: &str, generated: &str) -> String {
    let mut counts: BTreeMap<&str, i64> = BTreeMap::new();
    for line in generated.lines() {
        *counts.entry(line).or_default() += 1;
    }
    for line in committed.lines() {
        *counts.entry(line).or_default() -= 1;
    }

    let mut drift = String::new();
    let mut shown = 0usize;
    for line in committed.lines() {
        if let Some(count) = counts.get_mut(line) {
            emit_drifted_line('-', line, count, -1, &mut drift, &mut shown);
        }
    }
    for line in generated.lines() {
        if let Some(count) = counts.get_mut(line) {
            emit_drifted_line('+', line, count, 1, &mut drift, &mut shown);
        }
    }

    if shown > SHOWN_AT_MOST {
        drift.push_str(&format!(
            "… and {} more drifted lines\n",
            shown - SHOWN_AT_MOST
        ));
    }
    if drift.is_empty() {
        drift.push_str(
            "(no whole-line drift — the difference is in line endings or a trailing newline)\n",
        );
    }
    drift
}

/// Cap on drifted lines rendered; the count past the cap is still reported.
const SHOWN_AT_MOST: usize = 120;

/// Render one drifted line if `count` still owes one in `direction`
/// (negative: only in the committed file; positive: only in the migrated
/// database), consuming it so duplicates render exactly as often as they
/// drifted.
fn emit_drifted_line(
    prefix: char,
    line: &str,
    count: &mut i64,
    direction: i64,
    drift: &mut String,
    shown: &mut usize,
) {
    if *count * direction > 0 {
        *count -= direction;
        if *shown < SHOWN_AT_MOST {
            drift.push(prefix);
            drift.push(' ');
            drift.push_str(line);
            drift.push('\n');
        }
        *shown += 1;
    }
}
