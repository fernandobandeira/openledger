// BUG A-1, Go: the switch omits `expiry_reversal`. There is no `default`,
// and the function returns named zero values.
package main

import "fmt"

type AuthEventKind string

const (
	KindAuthorization  AuthEventKind = "authorization"
	KindIncremental    AuthEventKind = "incremental"
	KindAdvice         AuthEventKind = "advice"
	KindReversal       AuthEventKind = "reversal"
	KindClearing       AuthEventKind = "clearing"
	KindExpiry         AuthEventKind = "expiry"
	KindExpiryReversal AuthEventKind = "expiry_reversal"
)

type Effect struct {
	Delta            int64
	IncreaseSide     bool
	ClearsExpiryFlag bool
}

func Normalise(kind AuthEventKind, wire int64) (eff Effect, err error) {
	switch kind {
	case KindAuthorization, KindIncremental:
		return Effect{Delta: wire, IncreaseSide: true}, nil
	case KindClearing, KindReversal:
		return Effect{Delta: wire}, nil
	case KindAdvice:
		return Effect{Delta: wire}, nil
	case KindExpiry:
		return Effect{}, fmt.Errorf("expiry is a flag")
		// case KindExpiryReversal: <-- OMITTED
	}
	return // <-- silent: Effect{}, nil
}

func main() {
	e, err := Normalise(KindExpiryReversal, 0)
	fmt.Printf("go   Normalise(expiry_reversal) = %+v, err=%v\n", e, err)
	fmt.Printf("go   the flag that should have been cleared: ClearsExpiryFlag=%v\n", e.ClearsExpiryFlag)
}
