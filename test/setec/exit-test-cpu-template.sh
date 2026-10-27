#!/usr/bin/env bash
# exit-test-cpu-template.sh: a snapshot loads in a class with the m8i CPU
# template on the m8i nodes of an env (setec#239, setec#271).
#
# The CPU of a GitHub-hosted runner is never m8i, and Firecracker refuses the
# m8i template there, so the setec nightly run cannot prove this. The nodes of
# staging are m8i. Run it on a running env through the SSM forward:
#   make with-cluster ENV=<staging|drill> CMD='test/setec/exit-test-cpu-template.sh <setec checkout>'
# exit-test-setec-cpu-template.yml does that on main each day.
#
# What it does, in order:
#   1. It reads the setec version that the env runs: the one tag of the
#      setec images of the release. It also reads the release name.
#   2. It checks out that tag in the setec checkout, so the test code matches
#      the installed setec.
#   3. It refuses a setec version with no installed mode
#      (SETEC_E2E_INSTALLED_NAMESPACE): an older suite installs a second setec
#      release, and that is never done to an env.
#   4. It refuses a release with snapshots off, and it fails when the env has
#      no m8i node.
#   5. It runs `make e2e-cpu-template` against the installed setec. The suite
#      installs nothing. It makes one SandboxClass and its Sandboxes, and
#      deletes them.
#   6. It fails on a go test failure, on a SKIP, and when the scenario did not
#      PASS.
#
# Args: $1 the setec checkout, with its tags (or the env SETEC_DIR).
# Env:
#   SETEC_NS     the namespace of the setec release (default setec-system)
#   SANDBOX_NS   a Sandbox namespace that the release lists (default setec-sandboxes)
# Exit: 0 proved · 1 a step failed · 2 could not run
set -uo pipefail
SETEC_DIR="${1:-${SETEC_DIR:-}}"
SETEC_NS="${SETEC_NS:-setec-system}"
SANDBOX_NS="${SANDBOX_NS:-setec-sandboxes}"
SCENARIO="TestLauncher_CPUTemplateSnapshotLoads"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cannot() { printf 'could not run: %s\n' "$*" >&2; exit 2; }

if [ -z "$SETEC_DIR" ] || [ ! -d "$SETEC_DIR/.git" ]; then
  cannot "the first argument (or SETEC_DIR) must be a git checkout of setec, got '${SETEC_DIR}'"
fi
for t in kubectl git make go; do command -v "$t" >/dev/null 2>&1 || cannot "$t is not on PATH"; done

# The version is the tag of the setec images that run, not the chart label:
# the umbrella pins the setec chart and the setec image tags as separate
# values, so they can differ. Each setec image of the release must carry the
# same tag, or the test code of one version would run against the binaries
# of another.
images="$(kubectl -n "$SETEC_NS" get pods -l app.kubernetes.io/name=setec \
  -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null)" || images=""
tags=""
while IFS= read -r image; do
  [ -n "$image" ] || continue
  ref="${image%%@*}"              # drop the digest
  last="${ref##*/}"                # the last path part: name[:tag]
  case "${last%%:*}" in setec*) ;; *) continue ;; esac
  tag="${last#*:}"
  if [ "$tag" = "$last" ] || [ -z "$tag" ]; then
    fail "the setec image ${image} has no tag"
  fi
  tags="${tags}${tag}"$'\n'
done <<< "$images"
tags="$(printf '%s' "$tags" | sort -u | sed '/^$/d')"
[ -n "$tags" ] || fail "no setec Pod with a setec image in namespace ${SETEC_NS}"
[ "$(printf '%s\n' "$tags" | wc -l)" -eq 1 ] || fail "the setec images of the release carry different tags: $(printf '%s' "$tags" | tr '\n' ' ')"
version="$tags"
release="$(kubectl -n "$SETEC_NS" get pods -l app.kubernetes.io/name=setec \
  -o jsonpath='{.items[0].metadata.labels.app\.kubernetes\.io/instance}' 2>/dev/null)" || release=""
[ -n "$release" ] || fail "the setec Pods in namespace ${SETEC_NS} have no label app.kubernetes.io/instance"
printf 'the env runs setec %s, release %s\n' "$version" "$release"

git -C "$SETEC_DIR" -c advice.detachedHead=false checkout --quiet "refs/tags/${version}" \
  || cannot "the setec checkout has no tag ${version}. Check it out with its tags (fetch-depth: 0)"

grep -qs 'SETEC_E2E_INSTALLED_NAMESPACE' "$SETEC_DIR/test/e2e/installed_run_test.go" \
  || cannot "setec ${version} has no installed mode (SETEC_E2E_INSTALLED_NAMESPACE). Its suite would install a second setec release into the env, so the test does not run. setec#271 adds the mode"

# The scenario takes a Snapshot of one machine and loads it as another. A
# release with snapshots off has no Snapshot controller, so the Snapshot never
# gets a phase and the scenario times out after six minutes (run
# 40460536815). Refuse that release before the run.
args="$(kubectl -n "$SETEC_NS" get pods -l app.kubernetes.io/name=setec \
  -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.args}{"\n"}{end}{end}' 2>/dev/null)" || args=""
grep -q -- '--snapshots-enabled' <<< "$args" \
  || cannot "the setec release in ${SETEC_NS} runs with snapshots off (no --snapshots-enabled on the manager), so a Snapshot cannot load. Set snapshots.enabled and nodeAgent.enabled for this env"

m8i="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.labels.node\.kubernetes\.io/instance-type}{"\n"}{end}' 2>/dev/null | grep -c '^m8i\.')" || m8i=0
# The setec scenario places by the same label. On an EC2 env the node
# registers with its EC2 type (bootstrap/ec2/gibson, hosted#676).
[ "$m8i" -gt 0 ] || fail "the env has no m8i node (label node.kubernetes.io/instance-type), so the m8i CPU template cannot load"
printf 'the env has %s m8i node(s)\n' "$m8i"

context="$(kubectl config current-context 2>/dev/null)" || context=""
[ -n "$context" ] || cannot "kubectl has no current context"

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
(
  cd "$SETEC_DIR" && SETEC_E2E_CONTEXT="$context" \
    SETEC_E2E_INSTALLED_NAMESPACE="$SETEC_NS" \
    SETEC_E2E_RELEASE="$release" \
    SETEC_E2E_SANDBOX_NAMESPACE="$SANDBOX_NS" \
    make e2e-cpu-template
) 2>&1 | tee "$log"
status="${PIPESTATUS[0]}"

grep -Eq -- "--- SKIP: ${SCENARIO}" "$log" && fail "${SCENARIO} SKIPPED. A skipped scenario is not verified"
[ "$status" -eq 0 ] || fail "make e2e-cpu-template exited ${status}"
grep -Eq -- "--- PASS: ${SCENARIO}" "$log" || fail "${SCENARIO} did not report PASS"
printf 'PASS: a snapshot loads with the m8i CPU template on setec %s\n' "$version"
