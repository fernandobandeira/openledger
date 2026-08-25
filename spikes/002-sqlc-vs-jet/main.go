// Spike 002 — run the generated code against a live database.
// Compiling is not evidence. Executing is.
package main

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/google/uuid"

	"spike002/gen"
)

const dsn = "postgres://openledger:openledger@localhost:5433/openledger"

func main() {
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	must(err)
	defer pool.Close()
	q := gen.New(pool)

	// --- fixture -------------------------------------------------------
	_, err = pool.Exec(ctx, `
		DELETE FROM card_holds WHERE company_id = 'spike_co';
		DELETE FROM spend_controls WHERE card_id = 'spike_card';
		DELETE FROM credit_lines WHERE company_id = 'spike_co';
		INSERT INTO credit_lines (company_id, tenant_id, limit_minor, receivable_account_id)
		SELECT 'spike_co','t1',1000000, id FROM ledger_accounts WHERE purpose='customer_receivable';`)
	must(err)

	// --- 1. arrays round-trip natively? --------------------------------
	sc, err := q.UpsertSpendControls(ctx, gen.UpsertSpendControlsParams{
		CardID: "spike_card", CompanyID: "spike_co",
		CapMinor: ptr(int64(200000)),
		Period:   gen.NullControlPeriod{ControlPeriod: gen.ControlPeriodMonth, Valid: true},
		Timezone: "America/Sao_Paulo",
		AllowedMcc:       []int32{5812, 5814},
		BlockedMcc:       []int32{7995},
		AllowedMerchants: []string{"mrc_uber", "mrc_amzn"},
		Active:           true,
	})
	must(err)
	fmt.Printf("1. arrays        allowed_mcc=%v (%T)  merchants=%v (%T)\n",
		sc.AllowedMcc, sc.AllowedMcc, sc.AllowedMerchants, sc.AllowedMerchants)

	// --- 2. the auth transaction, end to end ---------------------------
	tx, err := pool.Begin(ctx)
	must(err)
	defer tx.Rollback(ctx)
	qtx := q.WithTx(tx)

	line, err := qtx.LockCreditLine(ctx, "spike_co") // SELECT ... FOR UPDATE
	must(err)

	held, err := qtx.GetHeld(ctx, gen.GetHeldParams{CompanyID: "spike_co", CardID: "spike_card"})
	must(err)
	fmt.Printf("2. FILTER agg    company_held=%d card_held=%d (types %T/%T)\n",
		held.CompanyHeld, held.CardHeld, held.CompanyHeld, held.CardHeld)

	available := line.LimitMinor - 0 - held.CompanyHeld
	fmt.Printf("   available     %d\n", available)

	dec, err := qtx.InsertHold(ctx, gen.InsertHoldParams{
		AuthID: "auth_spike_1", CompanyID: "spike_co", CardID: "spike_card",
		AmountMinor: 50000, State: gen.HoldStateOpen, Decision: gen.HoldDecisionApproved,
	})
	must(err)
	fmt.Printf("3. insert hold   decision=%s\n", dec)
	must(tx.Commit(ctx))

	// --- 3. duplicate auth: ON CONFLICT DO NOTHING RETURNING -----------
	_, err = q.InsertHold(ctx, gen.InsertHoldParams{
		AuthID: "auth_spike_1", CompanyID: "spike_co", CardID: "spike_card",
		AmountMinor: 50000, State: gen.HoldStateOpen, Decision: gen.HoldDecisionApproved,
	})
	fmt.Printf("4. duplicate     errors.Is(err, pgx.ErrNoRows) = %v  <- distinguishable\n",
		errors.Is(err, pgx.ErrNoRows))

	stored, err := q.GetStoredDecision(ctx, "auth_spike_1")
	must(err)
	fmt.Printf("   stored        decision=%s state=%s\n", stored.Decision, stored.State)

	// held now reflects the open hold, with no counter anywhere
	held2, err := q.GetHeld(ctx, gen.GetHeldParams{CompanyID: "spike_co", CardID: "spike_card"})
	must(err)
	fmt.Printf("5. held after    company_held=%d  <- the INSERT was the reduction\n", held2.CompanyHeld)

	// --- 4. THE LANDMINE: SUM() over zero rows -------------------------
	_, err = q.RawSumNoCoalesce(ctx, uuid.Nil)
	fmt.Printf("6. SUM, no rows  err = %v\n", err)
	if err != nil {
		fmt.Println("   ^^ sqlc typed this int64, but SQL SUM over zero rows is NULL.")
	}
}

func ptr[T any](v T) *T { return &v }

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "FATAL:", err)
		os.Exit(1)
	}
}
