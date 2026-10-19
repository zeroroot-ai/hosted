// Load test driver — spec production-eks-deploy task 36.
//
// Spawns N goroutines, each triggering mission-per-second against a
// target api.<domain> for a configurable duration. Emits a markdown
// report with p50/p95/p99 latency, error rate, throughput.
//
// Usage:
//
//	go run main.go \
//	  -target api.zeroroot.ai:443 \
//	  -mission-def-id <id> \
//	  -target-id <id> \
//	  -concurrency 100 \
//	  -duration 5m \
//	  -api-key-env GIBSON_API_KEY
//
// The MissionDefinition must be pre-created with a trivial DAG
// (single agent node that completes quickly, no external I/O).
package main

import (
	"context"
	"crypto/tls"
	"flag"
	"fmt"
	"log"
	"math"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	daemonpb "github.com/zeroroot-ai/sdk/api/gen/gibson/daemon/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/metadata"
)

var (
	flagTarget        = flag.String("target", "api.zeroroot.ai:443", "gRPC target (host:port)")
	flagMissionDefID  = flag.String("mission-def-id", "", "Pre-registered MissionDefinition ID")
	flagTargetID      = flag.String("target-id", "", "Target ID to reference on CreateMission")
	flagConcurrency   = flag.Int("concurrency", 100, "Concurrent goroutines")
	flagDuration      = flag.Duration("duration", 5*time.Minute, "Total test duration")
	flagRatePerWorker = flag.Duration("interval", 1*time.Second, "Delay between missions per worker")
	flagAPIKeyEnv     = flag.String("api-key-env", "GIBSON_API_KEY", "Env var holding the API key")
	flagInsecure      = flag.Bool("insecure", false, "Disable TLS (for Kind cluster testing)")
	flagReport        = flag.String("report", "load-report.md", "Output markdown file")
)

type result struct {
	latency time.Duration
	err     error
}

func main() {
	flag.Parse()
	if *flagMissionDefID == "" || *flagTargetID == "" {
		log.Fatal("-mission-def-id and -target-id required")
	}
	apiKey := os.Getenv(*flagAPIKeyEnv)
	if apiKey == "" {
		log.Fatalf("API key env var %s is empty", *flagAPIKeyEnv)
	}

	// Dial once, share across goroutines.
	var dialOpts []grpc.DialOption
	if *flagInsecure {
		dialOpts = append(dialOpts, grpc.WithTransportCredentials(credentials.NewTLS(&tls.Config{InsecureSkipVerify: true})))
	} else {
		dialOpts = append(dialOpts, grpc.WithTransportCredentials(credentials.NewTLS(&tls.Config{MinVersion: tls.VersionTLS12})))
	}
	conn, err := grpc.NewClient(*flagTarget, dialOpts...)
	if err != nil {
		log.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	client := daemonpb.NewDaemonServiceClient(conn)

	// Use a shared auth context. API key goes in the authorization
	// metadata; Envoy ext_authz validates and converts to signed
	// identity headers before the daemon sees the request.
	authCtx := func(parent context.Context) context.Context {
		return metadata.AppendToOutgoingContext(parent, "authorization", "Bearer "+apiKey)
	}

	log.Printf("load test: target=%s concurrency=%d duration=%s", *flagTarget, *flagConcurrency, *flagDuration)
	log.Printf("mission_definition_id=%s target_id=%s", *flagMissionDefID, *flagTargetID)

	ctx, cancel := context.WithTimeout(context.Background(), *flagDuration)
	defer cancel()

	var (
		totalInvoked atomic.Int64
		totalErrs    atomic.Int64
	)
	results := make(chan result, *flagConcurrency*64)
	var wg sync.WaitGroup

	for i := 0; i < *flagConcurrency; i++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			ticker := time.NewTicker(*flagRatePerWorker)
			defer ticker.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-ticker.C:
					start := time.Now()
					_, err := client.CreateMission(authCtx(ctx), &daemonpb.CreateMissionRequest{
						MissionDefinitionId: *flagMissionDefID,
						TargetId:            *flagTargetID,
						Metadata: map[string]string{
							"load_test_worker": fmt.Sprintf("%d", workerID),
						},
					})
					lat := time.Since(start)
					totalInvoked.Add(1)
					if err != nil {
						totalErrs.Add(1)
					}
					results <- result{latency: lat, err: err}
				}
			}
		}(i)
	}

	go func() {
		wg.Wait()
		close(results)
	}()

	var lats []time.Duration
	errCounts := map[string]int{}
	for r := range results {
		lats = append(lats, r.latency)
		if r.err != nil {
			errCounts[r.err.Error()]++
		}
	}

	report := buildReport(lats, errCounts, totalInvoked.Load(), totalErrs.Load(), *flagDuration)
	if err := os.WriteFile(*flagReport, []byte(report), 0o644); err != nil {
		log.Fatalf("write report: %v", err)
	}
	fmt.Fprintln(os.Stdout, report)
}

func buildReport(lats []time.Duration, errs map[string]int, total, errCount int64, duration time.Duration) string {
	sort.Slice(lats, func(i, j int) bool { return lats[i] < lats[j] })

	pct := func(p float64) time.Duration {
		if len(lats) == 0 {
			return 0
		}
		idx := int(math.Ceil(float64(len(lats))*p)) - 1
		if idx < 0 {
			idx = 0
		}
		if idx >= len(lats) {
			idx = len(lats) - 1
		}
		return lats[idx]
	}

	var sb strings.Builder
	fmt.Fprintf(&sb, "# Gibson load test report\n\n")
	fmt.Fprintf(&sb, "Generated: %s\n\n", time.Now().UTC().Format(time.RFC3339))
	fmt.Fprintf(&sb, "- Target: `%s`\n", *flagTarget)
	fmt.Fprintf(&sb, "- Concurrency: %d\n", *flagConcurrency)
	fmt.Fprintf(&sb, "- Duration: %s\n", duration)
	fmt.Fprintf(&sb, "- Requests/worker interval: %s\n\n", *flagRatePerWorker)

	fmt.Fprintf(&sb, "## Summary\n\n")
	fmt.Fprintf(&sb, "- Total CreateMission calls: %d\n", total)
	fmt.Fprintf(&sb, "- Errors: %d (%.2f%%)\n", errCount, 100*float64(errCount)/float64(max(total, 1)))
	fmt.Fprintf(&sb, "- Throughput: %.1f calls/s\n\n", float64(total)/duration.Seconds())

	fmt.Fprintf(&sb, "## Latency\n\n")
	fmt.Fprintf(&sb, "| p50 | p90 | p95 | p99 | max |\n|---|---|---|---|---|\n")
	fmt.Fprintf(&sb, "| %s | %s | %s | %s | %s |\n\n", pct(0.50), pct(0.90), pct(0.95), pct(0.99), pct(1.0))

	if len(errs) > 0 {
		fmt.Fprintf(&sb, "## Error distribution\n\n")
		for msg, n := range errs {
			fmt.Fprintf(&sb, "- `%s` : %d\n", msg, n)
		}
	}

	return sb.String()
}

func max(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}
