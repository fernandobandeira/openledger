#!/usr/bin/env bash
# Spike 022 — the sequential runner.
#
#   ./RUN.sh                the validation suite: short runs that prove the
#                           harness posts what it claims, that every shape
#                           leaves ten reconciliation checks at zero, and —
#                           this is the part that was missing — that the
#                           correctness gate REACHES RED when it should
#   ./RUN.sh a|b|c|d|e|f    one of SPEC.md's measurement sections
#   ./RUN.sh all            every section, in order
#   ./RUN.sh reduce FILE    medians and spread over a results file
#
# ONE HARNESS, ONE DATABASE, ONE MEASUREMENT AT A TIME. Spike 003's recorded
# methodology error was two harnesses on one database — "two harnesses on one
# database invalidate everything" — so nothing here backgrounds a run, and
# every configuration is followed by a settle before the next one starts.
#
# IDLENESS IS MEASURED, NOT ASSUMED, and no longer by loadavg: the 1-minute
# average has a 60-second time constant, so after a 3-second run and a
# 3-second settle `load_before` was a reading of the PREVIOUS configuration,
# not of this machine at rest. The harness now samples /proc/stat across one
# quiet second before it touches the database (`cpu_busy_pre_pct`) and again
# across the measurement window itself (`cpu_busy_window_pct`). loadavg is
# still recorded, as context, never as the oracle. Spike 003's banner exists
# because idleness went unchecked: the same configuration measured 833 and
# 482 clearings/s at loadavg ~1.5 and ~6.3.
#
# EVERY RESULT LINE IS ALSO WRITTEN TO A MACHINE-READABLE FILE with a run
# UUID and a monotonic sequence number. `tee -a` into one transcript with
# colliding labels cannot be reduced safely, and a spike whose numbers cannot
# be reduced safely has no numbers.
#
# Needs: a Rust toolchain, a PostgreSQL 18 to make scratch databases in
# (DATABASE_URL, default postgres://openledger:openledger@localhost:5433/...),
# the repo's own binary, which this script builds, and jq for `reduce`.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BIN="$HERE/harness/target/release/spike022"
TRANSCRIPT="$HERE/transcript.txt"
# A settle long enough for the cluster to quiesce — a checkpoint, an
# autovacuum pass — between configurations. It is no longer also doing the
# job of outwaiting a 60-second loadavg constant, because nothing depends on
# the loadavg any more.
SETTLE="${SETTLE:-10}"
# PASSES PER SECTION. The matrix is swept cell by cell, then swept AGAIN —
# passes are the outermost loop across the WHOLE run, not a repeat nested
# inside each cell and not even a repeat nested inside each section. Over a
# multi-hour run the machine drifts, and if repetitions are grouped the drift
# aliases directly onto the treatment: the cell measured at hour 1 and the
# cell measured at hour 3 differ by both mode and machine state, with no way
# to separate them afterwards. Interleaved, every cell sees every hour.
#
# B and C get more passes than the rest: they decide the affinity key and the
# composition question, and spike 003's own triplicates ranged 1.8x.
PASSES_A="${PASSES_A:-3}"
PASSES_B="${PASSES_B:-5}"
PASSES_C="${PASSES_C:-5}"
PASSES_D="${PASSES_D:-3}"
PASSES_E="${PASSES_E:-3}"
PASSES_F="${PASSES_F:-3}"
PASS=1
# Writer tasks = CONCURRENT DATABASE TRANSACTIONS, pinned across batch sizes.
# See `writers_and_offered_load` in main.rs: batch size and database
# concurrency are two knobs and welding them together made section B measure
# concurrency collapse and call it batching.
WRITERS="${WRITERS:-32}"
MODES="${MODES:-}"
# The clock excludes this much load at the front of every run: a cold pool,
# unprepared statements and an empty book are one-off costs.
WARMUP="${WARMUP:-5s}"
DURATION="${DURATION:-15s}"
# SECTION F'S WORKLOAD, IN ONE PLACE. Section C's whale, exactly: 32 tenants
# with 90% of the arrivals on t0, four companies, worker striping over 64
# stripes. See `section_f_cells` for why it is this and not 32 uniform
# tenants.
F_WORKLOAD="--mode worker --stripes 64 --tenants 32 --whale 0.9 --companies 4"

RUN_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N)"
RESULTS="${RESULTS:-$HERE/results-$RUN_UUID.jsonl}"
SEQ=0

hr() {
  printf '\n\033[1m== %s\033[0m\n' "$*"
  printf '\n== %s ==\n' "$*" >>"$TRANSCRIPT"
}

log() { printf '%s\n' "$*" | tee -a "$TRANSCRIPT"; }

# One configuration, and the exit status it is REQUIRED to produce. Most want
# 0; the gate-proving configurations want 2, and a 0 from those is the
# failure — an assertion that cannot go red is not an assertion.
measure_expecting() {
  local want="$1"; shift
  local label="$1"; shift
  local out status line
  SEQ=$((SEQ + 1))
  out="$(mktemp)"
  printf '\n--- %s  %s (seq %d, expecting exit %s)\n' "$(date -Is)" "$label" "$SEQ" "$want" >>"$TRANSCRIPT"
  printf 'cmd: %s --label %s %s\n' "$BIN" "$label" "$*" >>"$TRANSCRIPT"
  "$BIN" --label "$label" --run-uuid "$RUN_UUID" --seq "$SEQ" --pass "$PASS" \
         --results "$RESULTS" "$@" >"$out" 2>>"$TRANSCRIPT"
  status=$?
  line="$(tail -1 "$out")"
  rm -f "$out"
  printf '%s\n' "$line" | tee -a "$TRANSCRIPT"
  if [ "$status" -ne "$want" ]; then
    log "!!! $label EXITED $status, EXPECTED $want — this configuration is NOT a number. See the transcript."
  elif [ "$want" -ne 0 ]; then
    log "    $label exited $status as required — the gate reached red."
  fi
  case "$line" in
    *'"count_matches_clearings":false'*)
      log "!!! $label — the book's transaction count and the harness's clearing count DISAGREE." ;;
  esac
  sleep "$SETTLE"
}

measure() { measure_expecting 0 "$@"; }

# Closed-loop offered load: enough outstanding requests that every writer can
# fill a batch, and NOT MORE. Below `writers * batch` the fill rate is
# arithmetic rather than workload and the harness refuses to run it; far above
# it the surplus just sits in the accumulator's queue, where it inflates the
# window wait and the end-to-end latency without changing the throughput being
# measured. Takes the writer count explicitly, because several configurations
# pin their own and reading the global here queued 800 requests behind 8
# writers.
offered_for() { echo $(( $1 * $2 )); }

# `reduce` reads a file and builds nothing. Dispatched BEFORE the build
# banner so its JSON is the only thing on stdout and can be piped into jq.
if [ "${1:-}" = reduce ]; then
  file="${2:-}"
  [ -n "$file" ] || { echo "usage: $0 reduce FILE"; exit 2; }
  [ -s "$file" ] || { echo "no results in $file"; exit 1; }
  jq -s '
    def med: sort | if length == 0 then null
                    elif length % 2 == 1 then .[(length-1)/2]
                    else (.[length/2 - 1] + .[length/2]) / 2 end;
    def grp: .label | sub("_r[0-9]+$"; "");
    . as $all
    # The PASS-1 rate of each cell, as the baseline every later pass is measured
    # against. Drift is a property of the pass, not of the cell, so
    # normalizing per cell first is what separates the two.
    # A zero baseline is excluded, not divided by: a configuration whose
    # expected outcome is committing nothing (the duplicate-key abort) has no
    # rate to drift against.
    | ([$all[] | select(.pass == 1 and .clearings_per_s != null
                        and .clearings_per_s > 0)
        | {key: grp, value: .clearings_per_s}] | from_entries) as $base
    | {
      groups: (
        $all | group_by(grp)
        | map({
            group:        (.[0] | grp),
            n:            length,
            loop:         .[0].loop,
            mode:         .[0].mode,
            batch:        .[0].batch,
            writers:      .[0].writers,
            stripes:      .[0].stripes,
            reachable:    .[0].stripes_reachable,
            hazard:       .[0].lock_order_hazard,
            is_model:     .[0].hazard_is_a_model,
            # The open loop is a different question from the closed one and
            # needs different columns: what was OFFERED, what was ACHIEVED
            # against it, which dispatch policy was in force, and the p50 —
            # which is the whole of the section F claim, and which the closed
            # loop, always saturated, had no use for.
            dispatch:     .[0].dispatch_policy,
            window_ms:    .[0].window_ms,
            offered:      .[0].offered_rate,
            achieved_med: ([.[].achieved_rate_per_s | select(. != null)] | med),
            p50_med:      ([.[].latency_p50_ms] | med),
            rate_med:     ([.[].clearings_per_s | select(. != null)] | med),
            rate_min:     ([.[].clearings_per_s | select(. != null)] | min),
            rate_max:     ([.[].clearings_per_s | select(. != null)] | max),
            rate_samples: ([.[].clearings_per_s | select(. != null)] | length),
            fill_med:     ([.[].batch_fill] | med),
            p95_med:      ([.[].latency_p95_ms] | med),
            p99_med:      ([.[].latency_p99_ms] | med),
            deadlocks:    ([.[].deadlocks] | add),
            dl_per_1k:    ([.[].deadlocks_per_1k_statements] | med),
            oracle_med:   ([.[].oracle_s] | med),
            cpu_window:   ([.[].cpu_busy_window_pct] | med),
            all_reconciled:   (all(.[]; .reconciled)),
            all_counts_match: (all(.[]; .count_matches_clearings))
          })
        | sort_by(.group)),
      # DRIFT ACROSS PASSES, which is the thing a median inside a cell cannot
      # show. Each measurement is divided by the pass-1 rate of its OWN cell, so a
      # ratio below 1.0 that holds across a whole pass is the machine getting
      # slower, not a treatment being worse. cpu_busy_pre_pct is carried
      # alongside as an independent witness.
      drift: (
        [$all[] | select(.clearings_per_s != null and ($base[grp] // 0) > 0)
         | {pass: .pass, ratio: (.clearings_per_s / $base[grp]),
            cpu_pre: .cpu_busy_pre_pct}]
        | group_by(.pass)
        | map({
            pass:                 .[0].pass,
            cells:                length,
            rate_vs_pass1_med:    ([.[].ratio] | med),
            rate_vs_pass1_min:    ([.[].ratio] | min),
            rate_vs_pass1_max:    ([.[].ratio] | max),
            cpu_busy_pre_pct_med: ([.[].cpu_pre] | med)
          })
        | sort_by(.pass))
    }' "$file"
  exit 0
fi

hr "build"
build_ok=1
( cd "$ROOT" && cargo build -p openledger ) 2>&1 | tail -3 | tee -a "$TRANSCRIPT"
# ${PIPESTATUS[0]} is cargo's, not tail's. Without `set -e` and without this
# check the script sailed past a failed build, found the PREVIOUS binary
# still executable on disk, and measured it — silently, for the whole run.
# Every fix in this file would have been invisible.
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "cargo build -p openledger FAILED"; build_ok=0; }
( cd "$HERE/harness" && cargo build --release ) 2>&1 | tail -3 | tee -a "$TRANSCRIPT"
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "the harness FAILED to build"; build_ok=0; }
[ "$build_ok" -eq 1 ] || exit 1
# Reached only when both builds succeeded, so this now means what it says:
# the binary exists AND it is the one we just built.
[ -x "$BIN" ] || { echo "harness did not build"; exit 1; }
log "run:      $RUN_UUID"
log "results:  $RESULTS"
log "postgres: ${DATABASE_URL:-postgres://openledger:openledger@localhost:5433/openledger?sslmode=disable}"
log "rustc:    $(rustc --version)"
log "writers:  $WRITERS   warmup: $WARMUP   duration: $DURATION   settle: ${SETTLE}s"

section_smoke() {
  hr "validation — every shape must leave ten reconciliation checks at zero"

  # V0: today's writer. --mode none, one stripe, B = 1 runs the shipped
  # CLAIM_AND_APPEND with `0::smallint` where the literal 0 was — and now
  # with the real SHA-256 hash and the real versioned payload per post, so
  # the number it produces is quotable as a baseline rather than as "the
  # writer minus its hashing".
  measure v0_none_s1_b1     --mode none   --stripes 1  --batch 1 \
                            --writers 8 --concurrency 8 --warmup 2s --duration 5s
  measure v_random_s64_b1   --mode random --stripes 64 --batch 1 \
                            --writers 8 --concurrency 8 --warmup 2s --duration 5s
  # --mode tenant NEEDS more than one tenant. At --tenants 1 the stripe is
  # `hashtext('t0') % 64`, a constant, and the configuration is --mode none
  # under another name; the harness refuses it, and this is the proof.
  measure v_tenant_s64_b1   --mode tenant --stripes 64 --batch 1 --tenants 32 \
                            --writers 8 --concurrency 8 --warmup 2s --duration 5s
  measure_expecting 1 v_tenant_refuses_one_tenant \
                            --mode tenant --stripes 64 --batch 1 --tenants 1 \
                            --writers 8 --concurrency 8 --warmup 0s --duration 2s
  measure v_worker_s64_b25  --mode worker --stripes 64 --batch 25 --tenants 32 \
                            --writers 8 --concurrency "$(offered_for 8 25)" \
                            --warmup 2s --duration 5s
  # A starved batcher is refused, not measured: 8 writers and 8 outstanding
  # requests cannot fill a 25-member batch, and the fill rate that comes out
  # of trying is 8/8 = 1.
  measure_expecting 1 v_starved_batch_refused \
                            --mode worker --stripes 64 --batch 25 --tenants 32 \
                            --writers 8 --concurrency 8 --warmup 0s --duration 2s

  # At B = 1 the two selection placements are identical BY CONSTRUCTION.
  # Same throughput and the same book, or the harness is wrong.
  measure v_b1_perbatch  --mode random --select per-batch  --stripes 64 --batch 1 \
                         --path batched --writers 8 --concurrency 8 --warmup 2s --duration 5s
  measure v_b1_permember --mode random --select per-member --stripes 64 --batch 1 \
                         --path batched --writers 8 --concurrency 8 --warmup 2s --duration 5s

  # The admissibility gate commits the innocent members and refuses only the
  # guilty one; the fallback aborts and re-posts all 25 one at a time. Both
  # must leave ten zeros — and the gated run must leave 24 EVENTS, not 25:
  # the refused member's idempotency key must still be free.
  measure v_poison_gate   --experiment poison --batch 25 --mode worker --stripes 64
  measure v_poison_nogate --experiment poison --batch 25 --mode worker --stripes 64 \
                          --no-admissibility-gate

  # THE GATE, PROVED RED. Three ways, because a correctness gate that has
  # never failed is decoration.
  #
  #  1. one cached balance moved by one minor unit — the oracle must break
  measure_expecting 2 v_corrupt_must_break \
                       --mode none --stripes 1 --batch 1 --writers 8 --concurrency 8 \
                       --warmup 0s --duration 3s --corrupt
  #  2. two members of one batch carrying one idempotency key. A DESIGN
  #     FINDING, asserted rather than merely recorded: `ON CONFLICT DO
  #     NOTHING` tolerates the self-conflicting row and claims ONE event;
  #     `proceeding` then joins that one claimed row to BOTH members on
  #     (tenant, key); `txn` attempts two transactions against one event_id;
  #     and uq_txn__one_per_event (migrations/00001_baseline.sql:581) raises
  #     23505, aborting the WHOLE batch as an unmapped storage error. This
  #     configuration passes (exit 0) when that is what happens and goes red
  #     when it stops — nothing in SQL is being fixed here, but a real
  #     batching writer would have to de-duplicate keys before dispatch.
  measure v_duplicate_key_aborts_whole_batch \
                       --experiment poison --batch 25 --mode worker --stripes 64 \
                       --duplicate-key
  #  3. (the third is the count assertion, which every configuration above
  #     carries: `transactions_in_book` against `clearings`, checked in the
  #     harness and echoed by this runner.)

  # Section E's three mechanisms, each proved to work in both directions:
  # with the sort removed the arm must DEADLOCK, and the same arm with the
  # sort present must not. "A test that does not fail when the sort is
  # removed is not testing the sort."
  #
  # (a) THE REAL M2 HAZARD — a caller presenting its legs in reverse account
  #     order, on the single path, which is the only path where a caller can
  #     reach lock order at all.
  measure v_e_a_callerlegs_off_b1 --experiment deadlock \
                             --lock-order-hazard caller-legs --no-order-by \
                             --stripes 1 --batch 1 --companies 4 --tenants 1 \
                             --writers 16 --concurrency 16 --warmup 2s --duration 5s
  measure v_e_a_callerlegs_on_b1  --experiment deadlock \
                             --lock-order-hazard caller-legs \
                             --stripes 1 --batch 1 --companies 4 --tenants 1 \
                             --writers 16 --concurrency 16 --warmup 2s --duration 5s
  #     And the refusal that IS the finding: the same hazard on the batched
  #     path is provably inert, because the coalesce normalizes lock order
  #     before the insert. Refused rather than run.
  measure_expecting 1 v_e_a_callerlegs_refused_on_batched \
                             --experiment deadlock --lock-order-hazard caller-legs \
                             --no-order-by --stripes 1 --batch 25 --companies 4 \
                             --writers 8 --concurrency "$(offered_for 8 25)" \
                             --warmup 0s --duration 2s
  # (b) THE REAL BATCHED HAZARD — differing account subsets across concurrent
  #     batches, with NOTHING injected. If this deadlocks with the sort gone,
  #     it is the batched arm's evidence on its own merits.
  measure v_e_b_subsets_off_b25 --experiment deadlock \
                             --lock-order-hazard account-subsets --no-order-by \
                             --stripes 1 --batch 25 --companies 4 --tenants 1 \
                             --writers 8 --concurrency "$(offered_for 8 25)" \
                             --warmup 2s --duration 5s
  measure v_e_b_subsets_on_b25  --experiment deadlock \
                             --lock-order-hazard account-subsets \
                             --stripes 1 --batch 25 --companies 4 --tenants 1 \
                             --writers 8 --concurrency "$(offered_for 8 25)" \
                             --warmup 2s --duration 5s
  # (c) THE MODEL — an explicit DESC on half the writers. Labelled a model in
  #     the result line (`hazard_is_a_model: true`), a supplementary stress
  #     case, never the headline.
  measure v_e_c_descmodel_off_b25 --experiment deadlock \
                             --lock-order-hazard descending-model --no-order-by \
                             --stripes 1 --batch 25 --companies 4 --tenants 1 \
                             --writers 8 --concurrency "$(offered_for 8 25)" \
                             --warmup 2s --duration 5s

  # The mirror path, exercised at all. `--reversals` posts a reversal of each
  # clearing on the SINGLE path, which is the only thing that reaches the
  # mirror CTEs and their GROUP BY — half of M2's deliverable, and untested
  # until this line existed.
  measure v_reversals_b1 --mode none --stripes 1 --batch 1 --reversals \
                         --writers 8 --concurrency 8 --warmup 2s --duration 5s

  # Head-of-line: one uncommitted claim, and the 24 innocent members wait
  # with it. A cost to state, not a bug to fix.
  measure v_headofline --experiment headofline --batch 25 --mode worker --stripes 64 \
                       --hold-ms 1500

  # The OPEN loop, smoke-tested: arrivals at a fixed mean rate, a window that
  # expires half-empty, and a latency distribution that exists at all.
  measure v_open_50tps_b25 --mode worker --stripes 64 --tenants 32 --batch 25 \
                           --offered-rate 50 --window-ms 25 --writers 8 \
                           --warmup 2s --duration 5s
  # THE ARM THAT NEVER WAITS, smoke-tested on the same shape: it must post a
  # correct book like everything else, and its fill must be ~1 at 50 TPS —
  # which is the claim, not a defect. A fill of 25 here would mean the permit
  # is not being released on completion.
  measure v_open_50tps_oncompletion --mode worker --stripes 64 --tenants 32 --batch 25 \
                           --offered-rate 50 --dispatch on-completion --window-ms 0 \
                           --writers 8 --warmup 2s --duration 5s
  # A window under a policy that never opens one is refused, not ignored: the
  # result line carries `window_ms`, and a line reading `--window-ms 25` for a
  # run that never waited 25ms would be quoted as evidence about a window.
  measure_expecting 1 v_oncompletion_refuses_a_window \
                           --mode worker --stripes 64 --tenants 32 --batch 25 \
                           --offered-rate 50 --dispatch on-completion --window-ms 25 \
                           --writers 8 --warmup 0s --duration 2s
  # And it is refused on the experiments that hand-build their one batch and
  # never start an accumulator, where there is no dispatch policy to choose.
  measure_expecting 1 v_oncompletion_refuses_poison \
                           --experiment poison --batch 25 --mode worker --stripes 64 \
                           --dispatch on-completion --window-ms 0
}

# ======================================================================
# THE SECTIONS, AS ONE PASS EACH.
#
# Every `*_cells` function below sweeps its section's cells EXACTLY ONCE.
# Repetition is not their business: `sweep` drives passes as the outermost
# loop over the whole run, so cell 1 of section A and the last cell of
# section F are measured once per pass rather than three or five times in a
# row. The pass number rides in the label suffix AND in the result line's
# own `pass` field, so `reduce` can ask whether pass 5 was systematically
# slower than pass 1 instead of averaging that difference into the medians.
#
# sweep "fn:budget" ... — runs each fn once per pass, up to its own budget.
sweep() {
  local max=0 spec budget
  for spec in "$@"; do
    budget="${spec#*:}"
    [ "$budget" -gt "$max" ] && max="$budget"
  done
  for PASS in $(seq 1 "$max"); do
    hr "PASS $PASS of $max"
    for spec in "$@"; do
      budget="${spec#*:}"
      [ "$PASS" -le "$budget" ] && "${spec%%:*}"
    done
  done
}

# A · Selection x stripes, unbatched. This binary's own baseline — the number
# the roadmap says does not exist.
#
# `--tenants 32` for the four-mode comparison, and NOT because more tenants is
# more realistic: `--mode tenant` at one tenant chooses a constant stripe, so a
# one-tenant arm would have compared three real modes against a fourth that is
# `none` wearing a hash. The one-tenant, maximally-contended arm is kept for
# the three modes that can express it, because that is the shape ADR-0002's
# hot row actually has.
section_a_cells() {
  hr "A — selection x stripes, unbatched (B = 1), pass $PASS"
  for mode in none random tenant worker; do
    for tn in 1 32; do
      [ "$mode" = tenant ] && [ "$tn" = 1 ] && continue
      for s in 1 8 64; do
        for c in 8 16 32; do
          measure "a_${mode}_t${tn}_s${s}_c${c}_r${PASS}" \
            --mode "$mode" --stripes "$s" --batch 1 --tenants "$tn" \
            --writers "$c" --concurrency "$c" --warmup "$WARMUP" --duration "$DURATION"
        done
      done
    done
  done
}

# B · The cancellation matrix, with SELECTION PLACEMENT as its own axis.
#
# WRITERS IS PINNED AND THE OFFERED LOAD SCALES WITH B. The old shape held
# `--concurrency 32` fixed and let `writers = ceil(32/B)` fall out, which
# meant B = 100 ran on ONE writer with no lock contention in it at all, and
# the achievable fills at c = 32 were 1, 8, 16 and 32 — never the 10, 25 and
# 100 the matrix asks for. Database concurrency is now constant across the
# row, so the only thing that changes down a column is the batch size.
section_b_cells() {
  hr "B — the cancellation matrix x selection placement (writers = $WRITERS), pass $PASS"
  for mode in none random tenant worker; do
    for place in per-member per-batch; do
      for s in 1 64; do
        for b in 1 10 25 100; do
          measure "b_${mode}_${place//-/_}_s${s}_b${b}_r${PASS}" \
            --mode "$mode" --select "$place" --stripes "$s" --batch "$b" \
            --path batched --tenants 32 \
            --writers "$WRITERS" --concurrency "$(offered_for "$WRITERS" "$b")" \
            --warmup "$WARMUP" --duration "$DURATION"
        done
      done
    done
  done
}

# C · The whale, and the grouping policy. Fill rate and window wait are what
# make "may a batch span tenants?" a number instead of an argument. Derived
# the same way as B: writers pinned, offered load scaled with B.
section_c_cells() {
  hr "C — the whale (32 tenants, 90% on t0), pass $PASS"
  for mode in tenant worker; do
    for b in 1 25; do
      measure "c_${mode}_b${b}_spanning_r${PASS}" \
        --mode "$mode" --stripes 64 --batch "$b" --tenants 32 \
        --whale 0.9 --companies 4 \
        --writers "$WRITERS" --concurrency "$(offered_for "$WRITERS" "$b")" \
        --warmup "$WARMUP" --duration "$DURATION"
      measure "c_${mode}_b${b}_homogeneous_r${PASS}" \
        --mode "$mode" --stripes 64 --batch "$b" --tenants 32 \
        --whale 0.9 --companies 4 --tenant-homogeneous \
        --writers "$WRITERS" --concurrency "$(offered_for "$WRITERS" "$b")" \
        --warmup "$WARMUP" --duration "$DURATION"
    done
  done
}

# D · Failure isolation, and the two costs batching adds.
section_d_cells() {
  hr "D — poison pill and head-of-line blocking, pass $PASS"
  measure "d_poison_gate_r${PASS}"   --experiment poison --batch 25 --mode worker --stripes 64
  measure "d_poison_nogate_r${PASS}" --experiment poison --batch 25 --mode worker --stripes 64 \
                                     --no-admissibility-gate
  measure "d_hol_b25_r${PASS}"  --experiment headofline --batch 25 --mode worker --stripes 64 \
                                --hold-ms 1500
  measure "d_hol_b1_r${PASS}"   --experiment headofline --batch 1 --mode worker --stripes 64 \
                                --hold-ms 1500
}

# E · Deadlocks, and making the `ORDER BY` load-bearing.
#
# THREE MECHANISMS, REPORTED AS THREE. They are not one hazard and the result
# lines say which is which (`lock_order_hazard`, `hazard_is_a_model`):
#
#   (a) caller-legs, SINGLE path — the real M2 hazard. Half the writers
#       present their legs in reverse account order, so the delta arrays they
#       bind disagree, and with the sort gone the statement inserts in the
#       order it was handed. A caller can actually do this.
#
#   (b) account-subsets, BATCHED path — the real batched-path hazard, and it
#       needs NOTHING injected. Concurrent batches coalesce to different
#       account subsets because which per-company receivables a batch
#       collects varies; two partially-overlapping subsets can take the
#       shared house rows in different relative orders on their own. This is
#       the mechanism that produced the original eight deadlocks. If this arm
#       deadlocks with the sort removed, THIS is the batched evidence.
#
#   (c) descending-model, BATCHED path — a MODEL, labelled as one in the
#       result line, not merely in a comment. It forces the maximal adversity
#       (b) only sometimes reaches. Supplementary stress case, never the
#       headline, because no caller can cause it.
#
# The reason (a) has no batched counterpart is itself the finding, and the
# harness refuses the combination rather than running it inert: on the
# batched path `member_delta` coalesces every member down to (tenant,
# account, currency) BEFORE the insert, so member identity — and with it the
# order a caller presented its legs in — is gone before any row is locked. A
# caller cannot influence lock order there. The old `--reverse-half` ran that
# combination anyway and credited it with deadlocks (b) had produced.
#
# `--tenants 1` throughout, deliberately, and E is the one section that keeps
# it: the hazard is two writers taking the SAME two house rows in opposite
# orders, and 32 tenants would give them 32 independent pairs to not collide
# on. E uses `--mode none`, so the one-tenant tautology that disqualifies
# `--tenants 1` everywhere else does not arise.
section_e_cells() {
  hr "E — deadlocks, three mechanisms reported as three, pass $PASS"
  for s in 1 64; do
    for order in on off; do
      flag=""; [ "$order" = off ] && flag="--no-order-by"
      # (a) the real M2 hazard, on the path where a caller can cause it
      measure "e_a_callerlegs_single_s${s}_order_${order}_r${PASS}" \
        --experiment deadlock --lock-order-hazard caller-legs $flag \
        --stripes "$s" --batch 1 --companies 4 --tenants 1 \
        --writers 16 --concurrency 16 --warmup "$WARMUP" --duration "$DURATION"
      # (b) the real batched hazard, nothing injected
      measure "e_b_subsets_batched_s${s}_order_${order}_r${PASS}" \
        --experiment deadlock --lock-order-hazard account-subsets $flag \
        --stripes "$s" --batch 25 --companies 4 --tenants 1 \
        --writers 8 --concurrency "$(offered_for 8 25)" \
        --warmup "$WARMUP" --duration "$DURATION"
    done
    # (c) the model. Only with the sort removed: with it present every writer
    # is canonical whatever the hazard, so the arm would duplicate (b)'s
    # control exactly.
    measure "e_c_descmodel_batched_s${s}_order_off_r${PASS}" \
      --experiment deadlock --lock-order-hazard descending-model --no-order-by \
      --stripes "$s" --batch 25 --companies 4 --tenants 1 \
      --writers 8 --concurrency "$(offered_for 8 25)" \
      --warmup "$WARMUP" --duration "$DURATION"
  done
  # The mirror path, on the single writer. The batched statement hardcodes
  # 'posted' and stays that way (SPEC.md), so a reversal can only be measured
  # here — and it is half of M2's deliverable, so it is measured.
  measure "e_reversals_b1_r${PASS}" \
    --mode none --stripes 1 --batch 1 --reversals --companies 4 --tenants 1 \
    --writers 16 --concurrency 16 --warmup "$WARMUP" --duration "$DURATION"
}

# F · The load ADR-0002 actually derives. THE CLOSED LOOP CANNOT ANSWER THIS.
#
# A closed loop holds N requests outstanding and starts the next only when
# the last completes, so it always offers exactly as much load as the system
# will take: its batches are always full, and what it measures is a CEILING.
# ADR-0002's own peak is 20-50 TPS against a ~800/s baseline. At 50 TPS a
# 25-member window collects one or two members and expires — every request
# pays the whole window to be batched with almost nobody. Sizing a latency
# knob off a saturated batcher's throughput is the central error here, and
# this section is the correction: fixed arrival rate, real window, end-to-end
# latency percentiles, and the fill the window ACTUALLY collected.
# AND THE ARM THAT REFUSES THE WINDOW ALTOGETHER. A peer survey puts the
# fixed window in bad company: TigerBeetle uses NO timer and states its model
# as Nagle's (tigerbeetle#489 — "maintain at least one request in flight"), and
# PostgreSQL ships `commit_delay = 0` with `commit_siblings = 5` precisely
# because a delay is pure latency cost when nobody else is around to join. So
# `--dispatch on-completion` is measured against the windows rather than
# assumed away: it takes whatever is queued the moment a writer frees up,
# treats `--batch` as a ceiling and never as a target, and waits on nothing.
#
# THE WORKLOAD IS CONTENDED, and that is not a detail. Sections B and C
# already settled that batching only pays when a batch's members share
# accounts: at 32 uniform tenants B = 25 HALVED throughput (3900 -> 1428),
# because 25 members spread over 32 tenants coalesce to nothing. Running the
# dispatch comparison there would have measured a case where batching cannot
# help and called the resulting latency gap a policy result. This section uses
# section C's whale — 32 tenants with 90% of the load on t0 — which is the
# shape ADR-0002's hot row actually has and the one arm where batching is
# already known to pay at saturation (c_worker_b25_spanning 2177/s against
# c_worker_b1 1851/s). Its open-loop unbatched ceiling is ~1790/s, so the rate
# ladder below spans well under it, up to it, and past it.
section_f_cells() {
  hr "F — dispatch policy across the load ladder, contended (whale), pass $PASS"
  for rate in 20 50 200 800 2000; do
    # The one that never waits. `--window-ms 0` is REQUIRED with it and is not
    # the same thing: with no window the accumulator still drains the queue
    # into an unbounded channel, so the backlog forms as a line of one-member
    # batches and the coalesce never gets anything to coalesce. Measured: fill
    # 1.05 at 2000 TPS, against 18.5 for this arm.
    measure "f_r${rate}_oc_b25_r${PASS}" \
      $F_WORKLOAD --batch 25 --dispatch on-completion --window-ms 0 \
      --offered-rate "$rate" --writers "$WRITERS" \
      --warmup "$WARMUP" --duration "$DURATION"
    # The two fixed windows.
    for w in 5 25; do
      measure "f_r${rate}_w${w}_b25_r${PASS}" \
        $F_WORKLOAD --batch 25 --dispatch window --window-ms "$w" \
        --offered-rate "$rate" --writers "$WRITERS" \
        --warmup "$WARMUP" --duration "$DURATION"
    done
    # The no-batching control: the latency every arm above has to justify
    # itself against. `--window-ms 0` is cosmetic here — at B = 1 the fill
    # loop never runs a second iteration and there is nothing to wait for.
    measure "f_r${rate}_ctl_b1_r${PASS}" \
      $F_WORKLOAD --batch 1 --dispatch window --window-ms 0 \
      --offered-rate "$rate" --writers "$WRITERS" \
      --warmup "$WARMUP" --duration "$DURATION"
    # THE DIAGNOSTIC, and it is here because the first probe demanded it.
    # Dispatch-on-completion self-limits to `--writers` concurrent statements
    # BY CONSTRUCTION: a permit is held from the moment the accumulator forms
    # a batch until that batch has committed. Above the unbatched ceiling that
    # means 32 concurrent BATCHED statements on the whale's hot rows, which is
    # section B's concurrency collapse arriving by a different road — and a
    # windowed accumulator never gets there only because its own timer caps
    # how many statements it can put in flight. Without this arm the 2000 TPS
    # row cannot distinguish "the policy is wrong" from "the pool is too deep
    # for the batched path", and those need different answers.
    measure "f_r${rate}_oc_b25_w8_r${PASS}" \
      $F_WORKLOAD --batch 25 --dispatch on-completion --window-ms 0 \
      --offered-rate "$rate" --writers 8 \
      --warmup "$WARMUP" --duration "$DURATION"
  done
}

# ----------------------------------------------------------------------
# THE TRIMMED MATRIX. `./RUN.sh trim` runs it; the full sections above are
# unchanged and still what `a`..`f` run.
#
# Per configuration the wall cost is 1s (the /proc/stat idleness sample) +
# ~0.5s setup + WARMUP + DURATION + ~0.2s ANALYZE + ~5s oracle + SETTLE.
#
# THE ORACLE IS NOT THE PROBLEM, AND IT WAS NOT SUPERLINEAR. Measured on one
# configuration (random, 64 stripes, B=1, 8 writers) at three run lengths:
#
#     5s run   14,109 clearings   ~56k entries   oracle 3.97s   wall 13s
#    15s run   33,216 clearings  ~133k entries   oracle 4.70s   wall 23s
#    30s run   62,919 clearings  ~252k entries   oracle 5.29s   wall 39s
#
# Sublinear: 4.5x the book for 1.3x the oracle. The ~200s oracles inferred
# from the old transcript were STALE PLANNER STATISTICS — a scratch database
# is created, filled in seconds and read once, and with no `pg_statistic`
# rows the ten checks' joins over `ledger_entries` get nested loops. The
# same book measured 200s+ cold and 4.6s once autoanalyze had run. One
# explicit ANALYZE, costing 0.1-0.2s, is now taken before the oracle in
# every run, and it removes three minutes per configuration.
#
# The same three run lengths also settle DURATION: 2012.9 / 1950.4 / 1959.9
# clearings per second at 5s, 15s and 30s — within 3%. 15s is steady state.
#
# So the trim is not about the oracle. It is about axes that do not carry a
# question, and it keeps every cell A-F actually decide on.
trim_a_cells() {
  hr "A(trim) — selection x stripes, unbatched, pass $PASS"
  # Concurrency was a 3-point sweep with no question attached; c = 32 is the
  # interesting end and c = 8 is kept only on the V0 anchor.
  measure "a_v0_none_t1_s1_c8_r${PASS}" --mode none --stripes 1 --batch 1 --tenants 1 \
    --writers 8 --concurrency 8 --warmup "$WARMUP" --duration "$DURATION"
  # The full stripe sweep goes on the ONE-TENANT, maximally-contended arm,
  # because that is where a stripe is supposed to show and it is the shape
  # ADR-0002's hot row actually has. `tenant` cannot appear here — one tenant
  # is one constant stripe.
  for s in 1 8 64; do
    for mode in none random worker; do
      measure "a_${mode}_t1_s${s}_c32_r${PASS}" \
        --mode "$mode" --stripes "$s" --batch 1 --tenants 1 \
        --writers 32 --concurrency 32 --warmup "$WARMUP" --duration "$DURATION"
    done
  done
  # All four modes on one footing at the two endpoints. 32 tenants, because
  # `tenant` has nothing to spread over below that; endpoints only, because
  # the interior of the stripe sweep is answered by the arm above.
  for s in 1 64; do
    for mode in none random tenant worker; do
      measure "a_${mode}_t32_s${s}_c32_r${PASS}" \
        --mode "$mode" --stripes "$s" --batch 1 --tenants 32 \
        --writers 32 --concurrency 32 --warmup "$WARMUP" --duration "$DURATION"
    done
  done
}

# SPEC.md's own shape: the full grid at B {1, 25}, then B {10, 100} for the
# modes that survive. B = 1 per-member is DROPPED, not measured: the two
# placements are identical by construction at B = 1 and the smoke suite
# already proves it (v_b1_perbatch vs v_b1_permember).
trim_b_cells() {
  hr "B(trim) — the cancellation matrix, phase 1 (B in {1, 25}), pass $PASS"
  for mode in none random tenant worker; do
    for s in 1 64; do
      measure "b_${mode}_per_batch_s${s}_b1_r${PASS}" \
        --mode "$mode" --select per-batch --stripes "$s" --batch 1 \
        --path batched --tenants 32 --writers "$WRITERS" \
        --concurrency "$(offered_for "$WRITERS" 1)" \
        --warmup "$WARMUP" --duration "$DURATION"
      for place in per-member per-batch; do
        measure "b_${mode}_${place//-/_}_s${s}_b25_r${PASS}" \
          --mode "$mode" --select "$place" --stripes "$s" --batch 25 \
          --path batched --tenants 32 --writers "$WRITERS" \
          --concurrency "$(offered_for "$WRITERS" 25)" \
          --warmup "$WARMUP" --duration "$DURATION"
      done
    done
  done
}

trim_b2_cells() {
  hr "B(trim) — phase 2 (B in {10, 100}, MODES=${MODES:-worker random}), pass $PASS"
  for mode in ${MODES:-worker random}; do
    for place in per-member per-batch; do
      for b in 10 100; do
        measure "b2_${mode}_${place//-/_}_s64_b${b}_r${PASS}" \
          --mode "$mode" --select "$place" --stripes 64 --batch "$b" \
          --path batched --tenants 32 --writers "$WRITERS" \
          --concurrency "$(offered_for "$WRITERS" "$b")" \
          --warmup "$WARMUP" --duration "$DURATION"
      done
    done
  done
}

# The open loop is NOT trimmed at all: every rate on the ladder carries a
# question (20 and 50 TPS are the load ADR-0002 derives, 800 is under the
# unbatched ceiling, 2000 is past it) and so does every dispatch arm. `trim`
# runs section F whole.
trim_f_cells() { section_f_cells; }
case "${1:-smoke}" in
  smoke) section_smoke ;;
  a) sweep "section_a_cells:$PASSES_A" ;;
  b) sweep "section_b_cells:$PASSES_B" ;;
  c) sweep "section_c_cells:$PASSES_C" ;;
  d) sweep "section_d_cells:$PASSES_D" ;;
  e) sweep "section_e_cells:$PASSES_E" ;;
  f) sweep "section_f_cells:$PASSES_F" ;;
  all) sweep "section_a_cells:$PASSES_A" "section_b_cells:$PASSES_B" \
             "section_c_cells:$PASSES_C" "section_d_cells:$PASSES_D" \
             "section_e_cells:$PASSES_E" "section_f_cells:$PASSES_F" ;;
  trim) sweep "trim_a_cells:$PASSES_A" "trim_b_cells:$PASSES_B" \
              "section_c_cells:$PASSES_C" "section_d_cells:$PASSES_D" \
              "section_e_cells:$PASSES_E" "trim_f_cells:$PASSES_F" ;;
  trim-b2) sweep "trim_b2_cells:$PASSES_B" ;;
  *) echo "usage: $0 [smoke|a|b|c|d|e|f|all|trim|trim-b2|reduce FILE]"; exit 2 ;;
esac

hr "done — raw output is in $TRANSCRIPT, results in $RESULTS"
log "reduce with: $0 reduce $RESULTS"
