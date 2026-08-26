package main

import (
	"context"
	"fmt"
	"os"

	"github.com/jackc/pgx/v5"
)

// Exactly what sqlc generates for a Postgres enum: a string type.
type AuthEventKind string

const (
	KindAuthorization  AuthEventKind = "authorization"
	KindIncremental    AuthEventKind = "incremental"
	KindAdvice         AuthEventKind = "advice"
	KindReversal       AuthEventKind = "reversal"
	KindClearing       AuthEventKind = "clearing"
	KindExpiry         AuthEventKind = "expiry"
	KindExpiryReversal AuthEventKind = "expiry_reversal"
	// financial_authorization exists in the DB and is NOT here
)

func (e *AuthEventKind) Scan(src interface{}) error {
	switch s := src.(type) {
	case []byte:
		*e = AuthEventKind(s)
	case string:
		*e = AuthEventKind(s)
	default:
		return fmt.Errorf("unsupported scan type for AuthEventKind: %T", src)
	}
	return nil
}

func main() {
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		panic(err)
	}
	defer conn.Close(ctx)

	var k AuthEventKind
	if err := conn.QueryRow(ctx, `SELECT 'clearing'::auth_event_kind`).Scan(&k); err != nil {
		panic(err)
	}
	fmt.Printf("go  known variant decodes -> %q\n", k)

	var u AuthEventKind
	err = conn.QueryRow(ctx, `SELECT 'financial_authorization'::auth_event_kind`).Scan(&u)
	if err != nil {
		fmt.Printf("go  UNKNOWN variant REFUSED at decode: %v\n", err)
	} else {
		fmt.Printf("go  UNKNOWN variant decoded SILENTLY as %q, err=nil   <-- the bug\n", u)
	}

	// and the thing the type system permits with no database at all:
	made := AuthEventKind("not_a_kind_at_all")
	fmt.Printf("go  AuthEventKind(%q) compiles and is a valid value of the type\n", made)
}
