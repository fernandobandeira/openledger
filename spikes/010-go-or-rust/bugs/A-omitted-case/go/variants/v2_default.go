package variants

import "fmt"

type Kind string

const (
	K1 Kind = "authorization"
	K2 Kind = "incremental"
	K3 Kind = "advice"
	K4 Kind = "reversal"
	K5 Kind = "clearing"
	K6 Kind = "expiry"
	K7 Kind = "expiry_reversal"
)

// V2: same omission, but WITH a default clause -- the shape most real code has.
func NormaliseWithDefault(k Kind, wire int64) (int64, error) {
	switch k {
	case K1, K2:
		return wire, nil
	case K5, K4:
		return wire, nil
	case K3:
		return wire, nil
	case K6:
		return 0, fmt.Errorf("expiry is a flag")
	default:
		return 0, nil // "nothing to do" -- swallows expiry_reversal
	}
}

// V3: the same logic as an if/else chain rather than a switch.
func NormaliseIfElse(k Kind, wire int64) (int64, error) {
	if k == K1 || k == K2 {
		return wire, nil
	} else if k == K5 || k == K4 {
		return wire, nil
	} else if k == K3 {
		return wire, nil
	} else if k == K6 {
		return 0, fmt.Errorf("expiry is a flag")
	}
	return 0, nil
}

// V4: a map lookup, which is also common.
var table = map[Kind]int64{K1: 1, K2: 1, K3: 1, K4: -1, K5: -1, K6: 0}

func NormaliseMap(k Kind, wire int64) (int64, error) { return table[k] * wire, nil }
