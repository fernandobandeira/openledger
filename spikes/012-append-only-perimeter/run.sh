#!/usr/bin/env bash
# Reproduce every run in site/content/spikes/010-append-only-perimeter.md, in order.
# Each numbered file rebuilds the database first where it needs a clean one.
#   spikes/012-append-only-perimeter/run.sh > transcript.txt 2>&1
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
export PGPASSWORD=openledger
P="psql -h localhost -p 5433 -U openledger -d spike_wsa"
banner() { echo; echo "################ $1"; echo; }

banner "01 -- census of the shipped schema"
"$D/reset.sh" >/dev/null; $P -f "$D/01_census.sql"

banner "02 -- CHANNEL A: foreign keys skipped on the replication apply path"
$P -f "$D/02_replica_fk_hole.sql"

banner "03 -- CHANNEL A closed, and why the proposed spelling does not exist"
"$D/reset.sh" >/dev/null; $P -f "$D/03_enable_always_fk.sql"

banner "04 -- CHANNEL B: the pg_dump -a --disable-triggers restore path"
"$D/reset.sh" >/dev/null; $P -f "$D/04_restore_path.sql"

banner "05 -- CHANNEL C: inheritance, both directions"
"$D/reset.sh" >/dev/null; $P -f "$D/05_inheritance.sql"

banner "06 -- CHANNEL E: an account's owner can be nulled"
"$D/reset.sh" >/dev/null; $P -f "$D/06_owner_nulled.sql"

banner "07 -- CHANNEL D: DDL walks straight through append-only"
"$D/reset.sh" >/dev/null; $P -f "$D/07_ddl_rewrite.sql"

banner "08+09 -- the event-trigger guard, and everything it does not cover"
"$D/reset.sh" >/dev/null; $P -v ON_ERROR_STOP=1 -f "$D/08_event_trigger.sql"; $P -f "$D/09_guard_proof.sql"

banner "10 -- CHANNEL E closed declaratively, with no seventh trigger"
"$D/reset.sh" >/dev/null; $P -f "$D/10_owner_frozen.sql"

banner "11 -- the privilege boundary: who can reach any of this"
"$D/reset.sh" >/dev/null; $P -f "$D/11_privileges.sql"

banner "12 -- the role split"
"$D/12_role_split.sh"

banner "13 -- the proposed baseline edits, applied and attacked"
"$D/13_proposed_applies.sh"
