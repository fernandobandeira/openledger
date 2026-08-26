// Can an OUTSIDE package fabricate a Posting, bypassing NewPosting?
package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"spike010/ledger"
)

func main() {
	// 1. the zero value. Every field is unexported; this still compiles.
	var zero ledger.Posting
	fmt.Printf("go  var zero ledger.Posting        -> compiles, value = %+v\n", zero)

	// 2. the empty composite literal, from outside the package.
	empty := ledger.Posting{}
	fmt.Printf("go  ledger.Posting{}               -> compiles, value = %+v\n", empty)

	// 3. a whole slice of them
	fabricated := make([]ledger.Posting, 2)
	fmt.Printf("go  make([]ledger.Posting, 2)      -> compiles, len=%d\n", len(fabricated))

	// 4. hand it to the write API and see what the LEDGER does.
	ctx := context.Background()
	pool, err := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	if err != nil { panic(err) }
	defer pool.Close()
	tx, err := pool.Begin(ctx)
	if err != nil { panic(err) }
	defer tx.Rollback(ctx)
	id, err := ledger.PostTransaction(ctx, tx, "t1", ledger.Event{
		Kind: "fabricated", Source: "internal",
		IdempotencyKey: fmt.Sprintf("fab-%d", time.Now().UnixNano()),
		Payload: []byte(`{}`), EffectiveAt: time.Now(),
	}, fabricated)
	fmt.Printf("go  PostTransaction(zero postings) -> id=%v err=%v\n", id, err)
}
