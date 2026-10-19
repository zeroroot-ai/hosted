//go:build chaos
// +build chaos

// Package checkpointchaos exercises the SIGKILL recovery flow for Spec 4
// mission-checkpointing. It is a Go alternative to the sigkill_recovery_test.sh
// shell harness, intended for engineers who want to attach a debugger or run
// the assertion logic with Go's test runner.
//
// Build tag `chaos` keeps it out of standard test runs. Run with:
//
//	go test -tags=chaos -v -timeout 30m ./enterprise/deploy/tests/checkpoint/...
//
// The test shells out to `kubectl` and `gibson-cli`; both must be on PATH and
// pointed at a kind cluster with the daemon deployed (chart agent's
// `make deploy-local`).
//
// Spec: mission-checkpointing R8 (chaos test must prove SIGKILL → resume →
// no re-execution).
package checkpointchaos

import (
	"encoding/json"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

const (
	defaultNamespace             = "gibson"
	defaultDaemonPod             = "gibson-0"
	defaultMissionYAML           = "fixtures/5-tool-mission.yaml"
	defaultTool2Timeout          = 120 * time.Second
	defaultDaemonReadyTimeout    = 180 * time.Second
	defaultMissionFinishedTimout = 300 * time.Second
)

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func runCmd(t *testing.T, name string, args ...string) ([]byte, error) {
	t.Helper()
	t.Logf("$ %s %s", name, strings.Join(args, " "))
	cmd := exec.Command(name, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Logf("  → %v: %s", err, strings.TrimSpace(string(out)))
	}
	return out, err
}

func mustRun(t *testing.T, name string, args ...string) []byte {
	t.Helper()
	out, err := runCmd(t, name, args...)
	if err != nil {
		t.Fatalf("%s %s: %v\n%s", name, strings.Join(args, " "), err, out)
	}
	return out
}

type missionStatus struct {
	MissionID            string         `json:"mission_id"`
	Status               string         `json:"status"`
	CurrentNodeID        string         `json:"current_node_id"`
	RunningNodes         []string       `json:"running_nodes"`
	ToolExecutionCounts  map[string]int `json:"tool_execution_counts"`
}

func getStatus(t *testing.T, missionID string) missionStatus {
	t.Helper()
	out := mustRun(t, "gibson-cli", "mission", "status", missionID, "--json")
	var s missionStatus
	if err := json.Unmarshal(out, &s); err != nil {
		t.Fatalf("decode status: %v\n%s", err, out)
	}
	return s
}

// TestSIGKILLRecovery — Spec 4 R8.
func TestSIGKILLRecovery(t *testing.T) {
	namespace := envOr("NAMESPACE", defaultNamespace)
	pod := envOr("DAEMON_POD", defaultDaemonPod)
	missionYAML := envOr("MISSION_YAML", defaultMissionYAML)

	// Submit mission.
	out := mustRun(t, "gibson-cli", "mission", "run", "--yaml", missionYAML, "--json")
	var submit struct {
		MissionID string `json:"mission_id"`
	}
	if err := json.Unmarshal(out, &submit); err != nil {
		t.Fatalf("decode submit: %v\n%s", err, out)
	}
	if submit.MissionID == "" {
		t.Fatalf("empty mission_id from submit: %s", out)
	}
	t.Logf("mission submitted: %s", submit.MissionID)

	// Wait for tool-2 in flight.
	deadline := time.Now().Add(defaultTool2Timeout)
	for time.Now().Before(deadline) {
		st := getStatus(t, submit.MissionID)
		if strings.Contains(st.CurrentNodeID, "tool-2") || len(st.RunningNodes) >= 2 {
			t.Logf("tool-2 in flight (current=%q, running=%v)", st.CurrentNodeID, st.RunningNodes)
			break
		}
		time.Sleep(time.Second)
	}
	if time.Now().After(deadline) {
		t.Fatal("tool-2 did not start in time")
	}

	// SIGKILL the daemon pod.
	mustRun(t, "kubectl", "-n", namespace, "delete", "pod", pod,
		"--grace-period=0", "--force")

	// Wait for the pod to come Ready again.
	mustRun(t, "kubectl", "-n", namespace, "wait",
		"--for=condition=Ready",
		"--timeout="+defaultDaemonReadyTimeout.String(),
		"pod/"+pod)

	// Capture pre-resume tool counts.
	pre := getStatus(t, submit.MissionID)
	t.Logf("pre-resume counts: %v", pre.ToolExecutionCounts)

	// Resume.
	mustRun(t, "gibson-cli", "mission", "resume", submit.MissionID)

	// Wait for completion.
	deadline = time.Now().Add(defaultMissionFinishedTimout)
	var final missionStatus
	for time.Now().Before(deadline) {
		final = getStatus(t, submit.MissionID)
		if final.Status == "completed" || final.Status == "failed" || final.Status == "cancelled" {
			break
		}
		time.Sleep(2 * time.Second)
	}
	if final.Status != "completed" {
		t.Fatalf("mission did not complete; final status=%q", final.Status)
	}
	t.Logf("post-resume counts: %v", final.ToolExecutionCounts)

	// Assert no re-execution of tools 1 & 2.
	for _, tool := range []string{"tool-1", "tool-2"} {
		if pre.ToolExecutionCounts[tool] != final.ToolExecutionCounts[tool] {
			t.Errorf("%s was re-executed (%d -> %d)", tool,
				pre.ToolExecutionCounts[tool], final.ToolExecutionCounts[tool])
		}
	}
	// Assert tool 3 ran.
	if final.ToolExecutionCounts["tool-3"] < 1 {
		t.Errorf("tool-3 did not run after resume (count=%d)", final.ToolExecutionCounts["tool-3"])
	}
}
