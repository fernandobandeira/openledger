# Spike code

Throwaway. Not built by CI, not imported by `/internal` or `/cmd`, not held to the project's
quality bar. Each subdirectory is its own Go module so a spike's dependencies never leak into
the real `go.mod`.

Briefs and findings live in [`/docs/spikes`](../docs/spikes). Code here is evidence for those
findings; once a finding is written into an ADR, the code can be deleted without loss.
