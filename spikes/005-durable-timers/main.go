// Spike 005 — can a Postgres-backed job queue replace Temporal for this ledger?
//
// The whole timer requirement: "fire this once, N days from now, durably, and
// survive a restart." Longest chain is two steps. Handlers are already idempotent
// because of the event log, so at-least-once is sufficient.
//
// Tests River against the real requirement:
//  1. schedule a job days in the future
//  2. kill the process, restart, confirm the job survived
//  3. confirm it does NOT fire early
//  4. confirm a due job fires exactly once with N workers competing
//  5. confirm uniqueness (one hold -> one expiry timer, even if enqueued twice)
package main

import (
	"context"
	"fmt"
	"os"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/riverqueue/river"
	"github.com/riverqueue/river/riverdriver/riverpgxv5"
	"github.com/riverqueue/river/rivermigrate"
)

// HoldExpiry is the real job: a card authorization hold that must drop after ~7 days.
type HoldExpiry struct {
	AuthID string `json:"auth_id"`
}

func (HoldExpiry) Kind() string { return "hold_expiry" }

var fired atomic.Int64

type HoldExpiryWorker struct {
	river.WorkerDefaults[HoldExpiry]
}

func (w *HoldExpiryWorker) Work(ctx context.Context, job *river.Job[HoldExpiry]) error {
	fired.Add(1)
	fmt.Printf("     fired: auth=%s (attempt %d)\n", job.Args.AuthID, job.Attempt)
	return nil
}

func main() {
	ctx := context.Background()
	dsn := os.Getenv("OL_DSN")
	pool, err := pgxpool.New(ctx, dsn)
	must(err)
	defer pool.Close()

	// --- migrations: River owns its own tables -------------------------
	m, err := rivermigrate.New(riverpgxv5.New(pool), nil)
	must(err)
	res, err := m.Migrate(ctx, rivermigrate.DirectionUp, nil)
	must(err)
	fmt.Printf("  river migrations applied: %d\n", len(res.Versions))

	workers := river.NewWorkers()
	must(river.AddWorkerSafely(workers, &HoldExpiryWorker{}))

	client, err := river.NewClient(riverpgxv5.New(pool), &river.Config{
		Queues:        map[string]river.QueueConfig{river.QueueDefault: {MaxWorkers: 8}},
		Workers:       workers,
		FetchCooldown: 50 * time.Millisecond,
	})
	must(err)

	switch os.Args[1] {

	case "schedule":
		// a hold expiring 7 days out, and one already due
		_, err := client.Insert(ctx, HoldExpiry{AuthID: "auth_7day"},
			&river.InsertOpts{ScheduledAt: time.Now().Add(7 * 24 * time.Hour)})
		must(err)
		_, err = client.Insert(ctx, HoldExpiry{AuthID: "auth_due"},
			&river.InsertOpts{ScheduledAt: time.Now().Add(2 * time.Second)})
		must(err)
		// uniqueness: enqueue the SAME hold's expiry twice
		for i := 0; i < 2; i++ {
			r, err := client.Insert(ctx, HoldExpiry{AuthID: "auth_unique"},
				&river.InsertOpts{
					ScheduledAt: time.Now().Add(3 * time.Second),
					UniqueOpts:  river.UniqueOpts{ByArgs: true},
				})
			must(err)
			fmt.Printf("  unique insert #%d -> job %d, skipped_as_duplicate=%v\n",
				i+1, r.Job.ID, r.UniqueSkippedAsDuplicate)
		}
		fmt.Println("  scheduled. process now exits WITHOUT running any worker.")

	case "work":
		must(client.Start(ctx))
		fmt.Println("  worker started; running 6s")
		time.Sleep(6 * time.Second)
		must(client.Stop(ctx))
		fmt.Printf("  jobs fired this run: %d\n", fired.Load())
	}
}

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "FATAL:", err)
		os.Exit(1)
	}
}
