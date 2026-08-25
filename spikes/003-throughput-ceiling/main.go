// Spike 003 — throughput ceiling, and which knobs move it.
//
// Simulates the clearing path (v1-vision §06 step 02): one transaction header plus
// three balanced entries.
//
//	DR customer_receivable   500   per-COMPANY  -> spreads
//	CR network_settlement_pay 491  per-TENANT house account -> contends
//	CR interchange_revenue      9  per-TENANT house account -> contends
//
// Dimensions: -tenants, -companies, -stripes, -batch, -c.
package main

import (
	"context"
	"flag"
	"fmt"
	"math/rand"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const dsn = "postgres://openledger:openledger@localhost:5433/openledger?pool_max_conns=64"

type tenant struct {
	id        string
	companies []uuid.UUID
	netSettle []uuid.UUID // striped
	interch   []uuid.UUID // striped
}

var (
	nTenants   = flag.Int("tenants", 1, "distinct tenants, each with its OWN house accounts")
	nCompanies = flag.Int("companies", 500, "companies per tenant")
	nStripes   = flag.Int("stripes", 1, "stripes per house account")
	batch      = flag.Int("batch", 1, "clearings per DB transaction")
	conc       = flag.Int("c", 16, "concurrent writers")
	dur        = flag.Duration("d", 5*time.Second, "measurement duration")
	label      = flag.String("label", "", "row label")
)

func main() {
	flag.Parse()
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	must(err)
	defer pool.Close()

	tenants := setup(ctx, pool)

	var ok, errs int64
	stop := time.Now().Add(*dur)
	var wg sync.WaitGroup
	for w := 0; w < *conc; w++ {
		wg.Add(1)
		go func(seed int64) {
			defer wg.Done()
			rng := rand.New(rand.NewSource(seed))
			for time.Now().Before(stop) {
				if err := doBatch(ctx, pool, tenants, rng); err != nil {
					if atomic.AddInt64(&errs, 1) == 1 {
						fmt.Fprintln(os.Stderr, "first error:", err)
					}
					continue
				}
				atomic.AddInt64(&ok, int64(*batch))
			}
		}(int64(w)*7919 + 13)
	}
	wg.Wait()

	name := *label
	if name == "" {
		name = fmt.Sprintf("t=%d co=%d s=%d b=%d", *nTenants, *nCompanies, *nStripes, *batch)
	}
	e := dur.Seconds()
	fmt.Printf("%-26s c=%-3d  %8.0f clearings/s  %9.0f entries/s  err=%d\n",
		name, *conc, float64(ok)/e, float64(ok*3)/e, errs)
}

type posting struct {
	txn  uuid.UUID
	acct uuid.UUID
	dir  string
	amt  int64
}

// COALESCED batching. Naive batching deadlocks: sorting legs within one clearing
// does not order locks across a batch, so two workers take the same accounts in
// opposite orders. Fixing that requires batch-WIDE ordering -- and once you sort
// batch-wide, you may as well collapse N postings to one account into ONE upsert.
//
// That is exactly Formance's inverted write order: advance the balance row first,
// then derive each entry's running balance by walking backwards from the returned
// total. Their "demotion" of the running balance is what makes batching possible.
func doBatch(ctx context.Context, pool *pgxpool.Pool, ts []tenant, rng *rand.Rand) error {
	if *batch == 1 {
		tx, err := pool.Begin(ctx)
		if err != nil {
			return err
		}
		defer tx.Rollback(ctx)
		if err := clearing(ctx, tx, ts[rng.Intn(len(ts))], rng); err != nil {
			return err
		}
		return tx.Commit(ctx)
	}

	// build the batch up front, no DB contact
	txns := make([]uuid.UUID, 0, *batch)
	keys := make([]string, 0, *batch)
	tids := make([]string, 0, *batch)
	var posts []posting
	for i := 0; i < *batch; i++ {
		t := ts[rng.Intn(len(ts))]
		id := uuid.New()
		txns = append(txns, id)
		keys = append(keys, uuid.NewString())
		tids = append(tids, t.id)
		posts = append(posts,
			posting{id, t.companies[rng.Intn(len(t.companies))], "debit", 500},
			posting{id, t.netSettle[rng.Intn(len(t.netSettle))], "credit", 491},
			posting{id, t.interch[rng.Intn(len(t.interch))], "credit", 9})
	}

	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	for i := range txns {
		if _, err := tx.Exec(ctx, `
			INSERT INTO ledger_transactions (id, tenant_id, idempotency_key, idempotency_hash, kind, status, effective_at)
			VALUES ($1, $2, $3::text, sha256(convert_to($3::text,'UTF8')), 'clearing', 'posted', now())`,
			txns[i], tids[i], keys[i]); err != nil {
			return err
		}
	}

	// group postings by account, preserving order within each account
	byAcct := map[uuid.UUID][]int{}
	var order []uuid.UUID
	for i, p := range posts {
		if _, seen := byAcct[p.acct]; !seen {
			order = append(order, p.acct)
		}
		byAcct[p.acct] = append(byAcct[p.acct], i)
	}
	// BATCH-WIDE deterministic lock order -- this is what removes the deadlock
	for i := 1; i < len(order); i++ {
		for j := i; j > 0 && order[j].String() < order[j-1].String(); j-- {
			order[j], order[j-1] = order[j-1], order[j]
		}
	}

	type row struct {
		txn, acct uuid.UUID
		dir       string
		amt, seq  int64
		bal       int64
	}
	out := make([]row, 0, len(posts))

	for _, acct := range order {
		idxs := byAcct[acct]
		var in, outAmt int64
		for _, i := range idxs {
			if posts[i].dir == "debit" {
				in += posts[i].amt
			} else {
				outAmt += posts[i].amt
			}
		}
		// ONE upsert for N postings: advance balance by the total, seq by the count
		var fIn, fOut, fSeq int64
		if err := tx.QueryRow(ctx, `
			INSERT INTO ledger_account_balances (account_id, currency, input, output, last_seq)
			VALUES ($1,'USD',$2,$3,$4)
			ON CONFLICT (account_id, currency) DO UPDATE
			   SET input = ledger_account_balances.input + $2,
			       output = ledger_account_balances.output + $3,
			       last_seq = ledger_account_balances.last_seq + $4
			RETURNING input, output, last_seq`,
			acct, in, outAmt, int64(len(idxs))).Scan(&fIn, &fOut, &fSeq); err != nil {
			return err
		}
		// walk BACKWARDS from the final totals to derive each entry's seq + balance
		bal, seq := fIn-fOut, fSeq
		for k := len(idxs) - 1; k >= 0; k-- {
			p := posts[idxs[k]]
			out = append(out, row{p.txn, p.acct, p.dir, p.amt, seq, bal})
			if p.dir == "debit" {
				bal -= p.amt
			} else {
				bal += p.amt
			}
			seq--
		}
	}

	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"ledger_entries"},
		[]string{"transaction_id", "account_id", "direction", "amount_minor",
			"currency", "account_seq", "balance_after", "effective_at"},
		pgx.CopyFromSlice(len(out), func(i int) ([]any, error) {
			r := out[i]
			return []any{r.txn, r.acct, r.dir, r.amt, "USD", r.seq, r.bal, time.Now()}, nil
		})); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func clearing(ctx context.Context, tx pgx.Tx, t tenant, rng *rand.Rand) error {
	var txnID uuid.UUID
	err := tx.QueryRow(ctx, `
		INSERT INTO ledger_transactions (tenant_id, idempotency_key, idempotency_hash, kind, status, effective_at)
		VALUES ($1, $2::text, sha256(convert_to($2::text,'UTF8')), 'clearing', 'posted', now())
		RETURNING id`, t.id, uuid.NewString()).Scan(&txnID)
	if err != nil {
		return err
	}
	type leg struct {
		acct uuid.UUID
		dir  string
		amt  int64
	}
	legs := []leg{
		{t.companies[rng.Intn(len(t.companies))], "debit", 500},
		{t.netSettle[rng.Intn(len(t.netSettle))], "credit", 491},
		{t.interch[rng.Intn(len(t.interch))], "credit", 9},
	}
	// deterministic lock ordering (spike 001)
	for i := 1; i < len(legs); i++ {
		for j := i; j > 0 && legs[j].acct.String() < legs[j-1].acct.String(); j-- {
			legs[j], legs[j-1] = legs[j-1], legs[j]
		}
	}
	for _, l := range legs {
		if _, err := tx.Exec(ctx,
			`SELECT post_entry($1,$2,$3::ledger_direction,$4,'USD',now())`,
			txnID, l.acct, l.dir, l.amt); err != nil {
			return err
		}
	}
	return nil
}

func setup(ctx context.Context, pool *pgxpool.Pool) []tenant {
	_, err := pool.Exec(ctx,
		`TRUNCATE ledger_entries, ledger_transactions, ledger_account_balances, ledger_accounts CASCADE;`)
	must(err)

	out := make([]tenant, *nTenants)
	for ti := range out {
		t := tenant{id: fmt.Sprintf("tenant_%d", ti)}
		mk := func(kind string, n int) []uuid.UUID {
			ids := make([]uuid.UUID, n)
			rows := make([][]any, n)
			for i := range rows {
				rows[i] = []any{t.id, fmt.Sprintf("%s_%d_%d", kind, ti, i),
					fmt.Sprintf("%s_%d_%d", kind, ti, i)}
			}
			_, err := pool.CopyFrom(ctx, pgx.Identifier{"ledger_accounts"},
				[]string{"tenant_id", "owner_id", "purpose"},
				pgx.CopyFromSlice(n, func(i int) ([]any, error) {
					return []any{rows[i][0], rows[i][1], rows[i][2]}, nil
				}))
			must(err)
			must(pool.QueryRow(ctx, `SELECT array_agg(id ORDER BY owner_id)
				FROM ledger_accounts WHERE tenant_id=$1 AND owner_id LIKE $2`,
				t.id, kind+"_"+fmt.Sprint(ti)+"_%").Scan(&ids))
			return ids
		}
		t.companies = mk("co", *nCompanies)
		t.netSettle = mk("hns", *nStripes)
		t.interch = mk("hic", *nStripes)
		out[ti] = t
	}
	return out
}

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "FATAL:", err)
		os.Exit(1)
	}
}
