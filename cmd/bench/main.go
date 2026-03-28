package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
)

type Result struct {
	Name     string        `json:"name"`
	Duration time.Duration `json:"duration_ns"`
	Ms       int64         `json:"duration_ms"`
	Attempts int           `json:"attempts"`
	Err      string        `json:"error,omitempty"`
}

func (r Result) OK() bool { return r.Err == "" }

// connect retries until a successful SELECT 1 or timeout.
// pgx handles TLS, auth, and connection pooling internally —
// each attempt is a full connect+query cycle but in-process
// (~1ms overhead vs ~200ms for shelling out to psql).
func connect(ctx context.Context, connstr string, timeout time.Duration) Result {
	deadline := time.Now().Add(timeout)
	attempts := 0

	// Parse config once, use simple protocol to skip pg_type catalog queries
	// that add ~1s overhead on cold connections.
	cfg, err := pgx.ParseConfig(connstr)
	if err != nil {
		return Result{Attempts: 0, Err: fmt.Sprintf("parse config: %v", err)}
	}
	cfg.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol

	for time.Now().Before(deadline) {
		attempts++
		conn, err := pgx.ConnectConfig(ctx, cfg)
		if err != nil {
			time.Sleep(10 * time.Millisecond)
			continue
		}
		var n int
		err = conn.QueryRow(ctx, "SELECT 1").Scan(&n)
		conn.Close(ctx)
		if err == nil && n == 1 {
			return Result{Attempts: attempts}
		}
		time.Sleep(10 * time.Millisecond)
	}
	return Result{Attempts: attempts, Err: "timeout"}
}

func main() {
	var (
		connstrs    string
		iterations  int
		offsetMS    int
		timeoutSecs int
		jsonOut     bool
		waitReady   int
	)
	flag.StringVar(&connstrs, "connstrs", "", "comma-separated name=connstr pairs")
	flag.IntVar(&iterations, "iterations", 3, "wake/checkpoint cycles")
	flag.IntVar(&offsetMS, "offset-ms", 0, "stagger between wake calls in ms")
	flag.IntVar(&timeoutSecs, "timeout", 30, "per-connection timeout in seconds")
	flag.BoolVar(&jsonOut, "json", false, "output raw JSON results")
	flag.IntVar(&waitReady, "wait-ready", 5, "seconds to wait between cycles for re-checkpoint")
	flag.Parse()

	if connstrs == "" {
		fmt.Fprintln(os.Stderr, "usage: bench -connstrs 'name1=connstr1,name2=connstr2'")
		os.Exit(1)
	}

	type target struct {
		name    string
		connstr string
	}
	var targets []target
	for _, pair := range strings.Split(connstrs, ",") {
		idx := strings.Index(pair, "=")
		if idx < 1 {
			continue
		}
		targets = append(targets, target{name: pair[:idx], connstr: pair[idx+1:]})
	}

	if len(targets) == 0 {
		fmt.Fprintln(os.Stderr, "no valid connection strings")
		os.Exit(1)
	}

	timeout := time.Duration(timeoutSecs) * time.Second
	offset := time.Duration(offsetMS) * time.Millisecond
	ctx := context.Background()

	var allResults []Result

	for cycle := 1; cycle <= iterations; cycle++ {
		if cycle > 1 {
			fmt.Fprintf(os.Stderr, "  cycle %d/%d: waiting %ds for re-checkpoint...\n",
				cycle, iterations, waitReady)
			time.Sleep(time.Duration(waitReady) * time.Second)
		}

		fmt.Fprintf(os.Stderr, "  cycle %d/%d: waking %d instances (offset=%dms)...\n",
			cycle, iterations, len(targets), offsetMS)

		var mu sync.Mutex
		var wg sync.WaitGroup

		for i, t := range targets {
			if i > 0 && offset > 0 {
				time.Sleep(offset)
			}
			wg.Add(1)
			go func(t target) {
				defer wg.Done()
				start := time.Now()
				r := connect(ctx, t.connstr, timeout)
				r.Name = t.name
				r.Duration = time.Since(start)
				r.Ms = r.Duration.Milliseconds()

				mu.Lock()
				allResults = append(allResults, r)
				mu.Unlock()
			}(t)
		}
		wg.Wait()

		// Print cycle results immediately
		if !jsonOut {
			for _, r := range allResults[len(allResults)-len(targets):] {
				if r.OK() {
					fmt.Printf("  %-20s %6d ms  (attempts=%d)\n", r.Name, r.Ms, r.Attempts)
				} else {
					fmt.Printf("  %-20s %6d ms  FAIL: %s (attempts=%d)\n", r.Name, r.Ms, r.Err, r.Attempts)
				}
			}
		}
	}

	if jsonOut {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		enc.Encode(allResults)
		return
	}

	// Aggregate stats
	var oks []float64
	var fails int
	for _, r := range allResults {
		if r.OK() {
			oks = append(oks, float64(r.Ms))
		} else {
			fails++
		}
	}

	fmt.Println()
	if len(oks) == 0 {
		fmt.Printf("  All %d attempts failed!\n", len(allResults))
		os.Exit(1)
	}

	sort.Float64s(oks)
	n := len(oks)
	sum := 0.0
	for _, v := range oks {
		sum += v
	}

	pctl := func(p float64) float64 {
		idx := int(math.Ceil(p/100*float64(n))) - 1
		if idx < 0 {
			idx = 0
		}
		if idx >= n {
			idx = n - 1
		}
		return oks[idx]
	}

	fmt.Printf("  ──────────────────────────────────────\n")
	fmt.Printf("  Samples:   %d ok, %d failed\n", n, fails)
	fmt.Printf("\n")
	fmt.Printf("  Min:   %6.0f ms\n", oks[0])
	fmt.Printf("  Avg:   %6.0f ms\n", sum/float64(n))
	fmt.Printf("  p50:   %6.0f ms\n", pctl(50))
	fmt.Printf("  p95:   %6.0f ms\n", pctl(95))
	fmt.Printf("  p99:   %6.0f ms\n", pctl(99))
	fmt.Printf("  Max:   %6.0f ms\n", oks[n-1])
	fmt.Println()
}
