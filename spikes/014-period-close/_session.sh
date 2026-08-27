# Shared helper: drive a second psql session from the shell, deterministically.
#
# The experiments here all need "writer A is open and has NOT committed while the
# report runs". A `sleep` does not assert that, and a spike that depends on a sleep
# landing right is not evidence. So A reads from a FIFO, and the driver blocks until
# it can SEE A holding an xid in pg_stat_activity before it issues anything.
export PGPASSWORD=openledger
PG="psql -h localhost -p 5433 -U openledger -X -v ON_ERROR_STOP=1 -d spike_wsc"
SCRATCH="${TMPDIR:-/tmp}/ol-spike-014.$$"

session_open() {          # session_open <sql to run inside the open transaction>
    mkdir -p "$SCRATCH"; rm -f "$SCRATCH/fifo"; mkfifo "$SCRATCH/fifo"
    $PG -q -f "$SCRATCH/fifo" > "$SCRATCH/a.log" 2>&1 &
    SESSION_PID=$!
    exec 9>"$SCRATCH/fifo"
    printf 'BEGIN;\n%s\n' "$1" >&9
    # BLOCK until A actually holds a transaction id. This is the precondition the
    # experiment rests on, so it is asserted rather than slept for.
    for _ in $(seq 200); do
        [ "$($PG -Atqc "SELECT count(*) FROM pg_stat_activity
                        WHERE datname='spike_wsc' AND backend_xid IS NOT NULL")" = "1" ] && return 0
        sleep 0.05
    done
    echo "FAILED: writer A never took a transaction id"; cat "$SCRATCH/a.log"; exit 1
}

session_commit() { printf 'COMMIT;\n' >&9; exec 9>&-; wait "$SESSION_PID"; rm -rf "$SCRATCH"; }
