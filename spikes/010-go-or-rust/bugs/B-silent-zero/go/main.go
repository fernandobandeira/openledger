package main

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

const (
	tenant  = "t1"
	company = "bugco"
	// limit 1000.00, posted 950.00, held 0.00 -> a 200.00 auth MUST decline.
	authAmount = int64(20000)
)

// The struct ADR-0002 sanctions reusing: "hand-written SQL scanned by
// pgx.RowToStructByNameLax into the same generated structs."
type authInputs struct {
	LimitMinor  int64 `db:"limit_minor"`
	PostedMinor int64 `db:"posted_minor"`
	HeldMinor   int64 `db:"held_minor"`
}

func decide(in authInputs) (bool, int64) {
	available := in.LimitMinor - in.PostedMinor - in.HeldMinor
	return available >= authAmount, available
}

// v1 of the query: all three columns present.
const qGood = `
  SELECT cl.limit_minor,
         COALESCE((SELECT balance_after FROM ledger_entries
                    WHERE tenant_id=cl.tenant_id AND account_id=cl.receivable_account_id
                    ORDER BY account_seq DESC LIMIT 1), 0)   AS posted_minor,
         COALESCE((SELECT SUM(held_minor) FROM card_hold_groups
                    WHERE tenant_id=cl.tenant_id AND company_id=cl.company_id), 0) AS held_minor
    FROM credit_lines cl WHERE cl.tenant_id=$1 AND cl.company_id=$2`

// v2, after a refactor moved the posted lookup to "its own query" and nobody
// removed the struct field. THE COLUMN IS GONE FROM THE SELECT LIST.
const qDropped = `
  SELECT cl.limit_minor,
         COALESCE((SELECT SUM(held_minor) FROM card_hold_groups
                    WHERE tenant_id=cl.tenant_id AND company_id=cl.company_id), 0) AS held_minor
    FROM credit_lines cl WHERE cl.tenant_id=$1 AND cl.company_id=$2`

func main() {
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		panic(err)
	}
	defer conn.Close(ctx)

	scan := func(q string, fn pgx.RowToFunc[authInputs], label string) {
		rows, err := conn.Query(ctx, q, tenant, company)
		if err != nil {
			panic(err)
		}
		v, err := pgx.CollectOneRow(rows, fn)
		ok, avail := decide(v)
		fmt.Printf("%-42s err=%v\n%-42s scanned=%+v approved=%v available=%d\n",
			label, err, "", v, ok, avail)
		if err == nil && ok {
			fmt.Printf("%-42s >>> APPROVED %d against %d of real headroom. err was nil.\n", "", authAmount, int64(5000))
		}
		fmt.Println()
	}

	fmt.Println("truth: limit=100000 posted=95000 held=0 -> available=5000, a 20000 auth MUST decline")
	fmt.Println()
	scan(qGood, pgx.RowToStructByNameLax[authInputs], "B-1a Lax    / all columns present")
	scan(qDropped, pgx.RowToStructByNameLax[authInputs], "B-1b Lax    / posted_minor DROPPED")
	scan(qDropped, pgx.RowToStructByName[authInputs], "B-1c Strict / posted_minor DROPPED")

	// ---------- B-2: the dropped error. Go lets you spell this, and vet is happy.
	posted, _ := postedBalance(ctx, conn, uuid.MustParse("00000000-0000-0000-0000-000000000000"))
	fmt.Printf("B-2 posted, _ := postedBalance(wrongAccount) -> posted=%d (compiles, vets clean)\n", posted)
	ok3, avail3 := decide(authInputs{LimitMinor: 100000, PostedMinor: posted, HeldMinor: 0})
	fmt.Printf("B-2 approved=%v available=%d\n\n", ok3, avail3)

	// ---------- B-3: the nil deref on a genuinely NULL money column.
	var raw *int64
	if err := conn.QueryRow(ctx,
		`SELECT raw_amount FROM card_auth_events WHERE tenant_id=$1 AND raw_amount IS NULL LIMIT 1`,
		tenant).Scan(&raw); err != nil {
		fmt.Println("B-3 query err:", err)
	}
	fmt.Printf("B-3 raw_amount scanned as %v (nil=%v); `*raw` compiles unconditionally\n", raw, raw == nil)
	defer func() {
		if r := recover(); r != nil {
			fmt.Printf("B-3 PANIC: %v\n", r)
		}
	}()
	fmt.Printf("B-3 dereferencing: %d\n", *raw)
}

func postedBalance(ctx context.Context, conn *pgx.Conn, acct uuid.UUID) (int64, error) {
	var b int64
	err := conn.QueryRow(ctx,
		`SELECT balance_after FROM ledger_entries WHERE tenant_id=$1 AND account_id=$2
		 ORDER BY account_seq DESC LIMIT 1`, tenant, acct).Scan(&b)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, err
	}
	return b, err
}
