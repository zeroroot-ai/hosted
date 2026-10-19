#!/usr/bin/env bats
#
# teardown-webhook-sweep.bats — proves
# eks/gibson/scripts/eks-sweep-admission-webhooks.sh clears the webhooks that
# deadlock a teardown, and NEVER aborts the teardown itself (deploy#1592).
#
# WHY THIS SUITE EXISTS
# ---------------------
# On 2026-08-16 `terraform destroy` on staging removed the external-secrets
# workload before the ClusterSecretStore CRs it gates. Endpoints for
# external-secrets-webhook went empty, the ValidatingWebhookConfiguration
# `secretstore-validate` kept blocking, and the API server refused the very
# deletions terraform was asking for:
#
#   failed calling webhook "validate.clustersecretstore.external-secrets.io":
#   no endpoints available for service "external-secrets-webhook"
#   Error: context deadline exceeded
#
# Two ~40-minute teardown attempts failed before a human ran the sweep by hand.
#
# The sweep has two properties that both have to hold, and they pull against
# each other:
#   1. it must DELETE enough — every service-backed Validating/Mutating webhook
#      configuration, from any source, not a hardcoded list of today's names;
#   2. it must NEVER FAIL — it runs first on the teardown path, so a kubectl
#      error, missing binary, or already-destroyed cluster must degrade to a
#      no-op rather than abort the destroy that is trying to stop the billing.
# A test that only checked (1) would happily pass a script that exits 1 on an
# unreachable cluster and blocks every future teardown. Both are asserted here.
#
# kubectl is stubbed on PATH; nothing touches a real cluster (and could not —
# the cluster this was found on is mid-teardown).
#
# Run:
#   bats tests/harness/teardown-webhook-sweep.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SCRIPT="$REPO_ROOT/bootstrap/eks/gibson/scripts/eks-sweep-admission-webhooks.sh"

setup() {
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STUB_DIR" "$STATE"
  PATH="$STUB_DIR:$PATH"
  export PATH STATE
}

write_kubectl_stub() {
  cat > "$STUB_DIR/kubectl"
  chmod +x "$STUB_DIR/kubectl"
}

# The live staging shape: ESO's secretstore-validate plus the platform's own
# service-backed webhooks, one url-backed webhook, and the CEL policies that
# must be left alone. `get` answers the script's jsonpath; `delete` records.
write_live_shape_stub() {
  write_kubectl_stub <<'SH'
#!/usr/bin/env bash
S="$STATE"
verb="$1"; kind="$2"; shift 2
case "$verb" in
  get)
    case "$kind" in
      validatingwebhookconfigurations)
        # name <TAB> svcname,svcns; ...
        printf 'secretstore-validate\texternal-secrets-webhook,external-secrets;\n'
        printf 'externalsecret-validate\texternal-secrets-webhook,external-secrets;\n'
        printf 'cert-manager-webhook\tcert-manager-webhook,cert-manager;\n'
        printf 'cnpg-validating-webhook-configuration\tcnpg-webhook-service,gibson;\n'
        printf 'setec-validating-webhook\tsetec-webhook,setec-system;\n'
        printf 'offsite-validator\t,;\n'
        ;;
      mutatingwebhookconfigurations)
        printf 'cnpg-mutating-webhook-configuration\tcnpg-webhook-service,gibson;\n'
        printf 'aws-load-balancer-webhook\taws-load-balancer-webhook-service,kube-system;\n'
        ;;
      *) ;;
    esac
    exit 0 ;;
  delete)
    echo "DELETE $kind $1" >> "$S/trace"
    exit 0 ;;
esac
echo "$*" >> "${UNDECLARED_LOG:-$STATE/undeclared}"; echo "kubectl stub: undeclared call: $*" >&2
exit 1
SH
}

@test "sweeps every service-backed webhook config, from chart AND terraform-installed addons" {
  write_live_shape_stub
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  # The one that actually deadlocked staging.
  grep -q "DELETE validatingwebhookconfigurations secretstore-validate" "$STATE/trace"
  # ... and its sibling, which would have deadlocked the next attempt.
  grep -q "DELETE validatingwebhookconfigurations externalsecret-validate" "$STATE/trace"
  # Terraform-installed addons (invisible to any chart render).
  grep -q "DELETE validatingwebhookconfigurations cert-manager-webhook" "$STATE/trace"
  grep -q "DELETE mutatingwebhookconfigurations aws-load-balancer-webhook" "$STATE/trace"
  # Chart-installed.
  grep -q "DELETE validatingwebhookconfigurations cnpg-validating-webhook-configuration" "$STATE/trace"
  grep -q "DELETE validatingwebhookconfigurations setec-validating-webhook" "$STATE/trace"
  grep -q "DELETE mutatingwebhookconfigurations cnpg-mutating-webhook-configuration" "$STATE/trace"
}

@test "leaves url-backed webhooks alone (they do not depend on cluster endpoints)" {
  write_live_shape_stub
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q "offsite-validator" "$STATE/trace"
  [[ "$output" == *"offsite-validator is url-backed"* ]]
}

@test "never deletes ValidatingAdmissionPolicy or its Binding" {
  # setec#159 ships these; they are CEL, evaluated in-process, and cannot
  # deadlock on missing endpoints. The stub records ANY get/delete of them so a
  # future 'sweep everything' rewrite trips this test.
  write_kubectl_stub <<'SH'
#!/usr/bin/env bash
S="$STATE"
echo "$*" >> "$S/allcalls"
case "$*" in
  # The two lists the sweep reads, and nothing else: a read of an admission
  # policy is an undeclared call, and the assertion below names it.
  "get validatingwebhookconfigurations -o jsonpath="*|"get mutatingwebhookconfigurations -o jsonpath="*) exit 0 ;;
  "delete "*) echo "DELETE $2 $3" >> "$S/trace"; exit 0 ;;
  *) echo "$*" >> "${UNDECLARED_LOG:-$STATE/undeclared}"; echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -qi "validatingadmissionpolicy" "$STATE/allcalls"
  [ ! -f "$STATE/trace" ] || ! grep -qi "validatingadmissionpolicy" "$STATE/trace"
}

@test "cluster already gone: kubectl fails on every call, sweep still exits 0" {
  # The re-run case. A teardown gets re-run after a partial destroy, so the
  # cluster may be half or fully destroyed. Aborting here would block the
  # destroy that is trying to stop the bill.
  write_kubectl_stub <<'SH'
#!/usr/bin/env bash
echo "Unable to connect to the server: dial tcp: lookup ...: no such host" >&2
exit 1
SH
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unreachable or already gone"* ]]
}

@test "expired credentials: kubectl exits non-zero, sweep still exits 0" {
  write_kubectl_stub <<'SH'
#!/usr/bin/env bash
echo "error: You must be logged in to the server (Unauthorized)" >&2
exit 1
SH
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "kubectl missing from PATH entirely: sweep still exits 0" {
  # No stub written at all, and PATH reduced so the real kubectl cannot be
  # found either — a runner without kubectl installed must not fail teardown.
  # bash is invoked by ABSOLUTE path: with PATH stripped to the empty stub dir
  # `env ... bash` would fail 127 on bash itself and prove nothing.
  local bash_abs; bash_abs="$(command -v bash)"
  run env PATH="$STUB_DIR" KUBECTL=kubectl "$bash_abs" "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not on PATH"* ]]
}

@test "a delete that fails is reported with the manual command, but does not fail the sweep" {
  write_kubectl_stub <<'SH'
#!/usr/bin/env bash
case "$1" in
  get)
    [ "$2" = "validatingwebhookconfigurations" ] && printf 'stuck-hook\tsvc,ns;\n'
    exit 0 ;;
  delete)
    echo "error: timed out waiting for the condition" >&2
    exit 1 ;;
esac
echo "$*" >> "${UNDECLARED_LOG:-$STATE/undeclared}"; echo "kubectl stub: undeclared call: $*" >&2
exit 1
SH
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not delete"* ]]
  # The operator must be told exactly how to clear it by hand.
  [[ "$output" == *"kubectl delete validatingwebhookconfigurations stuck-hook"* ]]
}

@test "idempotent: a second run over an already-swept cluster is a clean no-op" {
  write_kubectl_stub <<'SH'
#!/usr/bin/env bash
case "$*" in
  # Both lists are empty: nothing is left.
  "get validatingwebhookconfigurations -o jsonpath="*|"get mutatingwebhookconfigurations -o jsonpath="*) exit 0 ;;
  "delete "*) echo "DELETE $2 $3" >> "$STATE/trace"; exit 0 ;;
  *) echo "$*" >> "${UNDECLARED_LOG:-$STATE/undeclared}"; echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no service-backed admission webhooks present"* ]]
  [ ! -f "$STATE/trace" ]
}

@test "DRY_RUN reports without deleting" {
  write_live_shape_stub
  run env DRY_RUN=1 bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"would delete"* ]]
  [ ! -f "$STATE/trace" ]
}

# ---------------------------------------------------------------------------
# The Terminating-namespace finalizer sweep patches ONLY objects that carry a
# finalizer. Patching everything was O(every object in the namespace) at one
# kubectl round trip each, and because clearing finalizers succeeds on an
# object that has none, it also claimed to have cleared them. Measured on the
# 2026-09-14 staging teardown: 1721 patches, 1389 on Events — a kind that
# cannot hold a finalizer and cannot pin a namespace.
# ---------------------------------------------------------------------------
@test "the finalizer sweep patches only objects that carry a finalizer, and says only that" {
  write_kubectl_stub <<'SH'
#!/usr/bin/env bash
S="$STATE"
echo "$*" >> "$S/allcalls"
case "$*" in
  *"get ns"*)
    # One namespace, Terminating, so the sweep engages.
    printf 'gibson
' ;;
  *"api-resources"*)
    printf 'externalsecrets.external-secrets.io
events
' ;;
  *"get externalsecrets.external-secrets.io"*)
    # The jsonpath asks for names of items WITH finalizers. One is stuck.
    printf 'gibson-db-secrets
' ;;
  *"get events"*)
    # Events never carry finalizers, so the same query returns nothing.
    printf '' ;;
  *patch*)
    echo "PATCH $*" >> "$S/trace" ;;
  # The other calls of eks-pre-destroy.sh: each answers an empty list.
  "get ingress -A --no-headers") exit 0 ;;
  "get validatingwebhookconfigurations -o jsonpath="*) exit 0 ;;
  "get mutatingwebhookconfigurations -o jsonpath="*) exit 0 ;;
  "delete nodepool.karpenter.sh --all --wait=false") exit 0 ;;
  "delete ec2nodeclass.karpenter.k8s.aws --all --wait=false") exit 0 ;;
  "get svc -A --no-headers") exit 0 ;;
  "delete svc gibson-envoy -n gibson --wait=false") exit 0 ;;
  "get pods -A -o jsonpath="*) exit 0 ;;
  "get ns -o jsonpath="*) exit 0 ;;
  *) echo "$*" >> "${UNDECLARED_LOG:-$STATE/undeclared}"; echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
exit 0
SH
  cd "$REPO_ROOT/bootstrap/eks/gibson"
  run env CONFIRM=reset WORKSPACE=zeroroot-ai-staging AWS_PAGER="" \
    bash scripts/eks-pre-destroy.sh
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # The stuck ExternalSecret is patched; no Event is.
  grep -q 'PATCH .*externalsecrets.external-secrets.io gibson-db-secrets' "$STATE/trace"
  [ "$(grep -c 'PATCH .*events' "$STATE/trace" || true)" = "0" ]
  # And the line it prints names what it actually cleared.
  [[ "$output" == *"cleared finalizers on externalsecrets.external-secrets.io/gibson-db-secrets"* ]]
  [[ "$output" != *"cleared finalizers on events"* ]]
}

# ---------------------------------------------------------------------------
# The load balancer controller gets to finish (2026-09-14).
#
# Deleting a LoadBalancer Service tells the AWS LB controller to delete the
# NLB and its target groups. The controller clears the Service's
# `service.k8s.aws/resources` finalizer only once those cloud objects are
# gone, so the Service leaving the API server IS the completion signal.
# Without a wait the destroy races the controller and kills it mid-cleanup:
# the 2026-09-14 staging teardown left target group
# k8s-gibson-gibsonen-31e3236765 in a VPC that no longer exists.
# ---------------------------------------------------------------------------
@test "pre-destroy waits for the LoadBalancer Services to actually go" {
  write_kubectl_stub <<'SH'
#!/usr/bin/env bash
S="$STATE"
echo "$*" >> "$S/allcalls"
case "$*" in
  *"get svc -A"*)
    # Present on the first look, gone on the second: the controller finished.
    n=$(cat "$S/svcpolls" 2>/dev/null || echo 0)
    echo $((n + 1)) > "$S/svcpolls"
    [ "$n" -ge 1 ] || printf 'gibson gibson-envoy LoadBalancer 172.20.0.250 a.elb.amazonaws.com 443\n'
    ;;
  *"get ingress -A"*) : ;;
  # The other calls of eks-pre-destroy.sh: each answers an empty list.
  "get ingress -A --no-headers") exit 0 ;;
  "get validatingwebhookconfigurations -o jsonpath="*) exit 0 ;;
  "get mutatingwebhookconfigurations -o jsonpath="*) exit 0 ;;
  "delete nodepool.karpenter.sh --all --wait=false") exit 0 ;;
  "delete ec2nodeclass.karpenter.k8s.aws --all --wait=false") exit 0 ;;
  "get svc -A --no-headers") exit 0 ;;
  "delete svc gibson-envoy -n gibson --wait=false") exit 0 ;;
  "get pods -A -o jsonpath="*) exit 0 ;;
  "get ns -o jsonpath="*) exit 0 ;;
  *) echo "$*" >> "${UNDECLARED_LOG:-$STATE/undeclared}"; echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
exit 0
SH
  cd "$REPO_ROOT/bootstrap/eks/gibson"
  run env CONFIRM=reset WORKSPACE=zeroroot-ai-staging AWS_PAGER="" \
    bash scripts/eks-pre-destroy.sh
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"Waiting up to"* ]]
  [[ "$output" == *"the controller released its cloud objects"* ]]
  # Ingresses are deleted too, or an ALB and its target groups orphan the
  # same way the NLB's did.
  grep -q 'get ingress -A' "$STATE/allcalls"
}

# FAILING FIXTURE: a controller that never finishes. The destroy must still
# run. An orphan target group costs nothing and the post-destroy verification
# names it; refusing to destroy the cluster leaves the WHOLE cluster billing.
@test "FAILING FIXTURE: a load balancer that never drains does not stop the destroy" {
  write_kubectl_stub <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$STATE/allcalls"
case "$*" in
  *"get svc -A"*) printf 'gibson gibson-envoy LoadBalancer 172.20.0.250 a.elb.amazonaws.com 443\n' ;;
  # The other calls of eks-pre-destroy.sh: each answers an empty list.
  "get ingress -A --no-headers") exit 0 ;;
  "get validatingwebhookconfigurations -o jsonpath="*) exit 0 ;;
  "get mutatingwebhookconfigurations -o jsonpath="*) exit 0 ;;
  "delete nodepool.karpenter.sh --all --wait=false") exit 0 ;;
  "delete ec2nodeclass.karpenter.k8s.aws --all --wait=false") exit 0 ;;
  "get svc -A --no-headers") exit 0 ;;
  "delete svc gibson-envoy -n gibson --wait=false") exit 0 ;;
  "get pods -A -o jsonpath="*) exit 0 ;;
  "get ns -o jsonpath="*) exit 0 ;;
  *) echo "$*" >> "${UNDECLARED_LOG:-$STATE/undeclared}"; echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
exit 0
SH
  cd "$REPO_ROOT/bootstrap/eks/gibson"
  run env CONFIRM=reset WORKSPACE=zeroroot-ai-staging AWS_PAGER="" \
    LB_DRAIN_TIMEOUT=1 bash scripts/eks-pre-destroy.sh
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"still present after 1s"* ]]
  [[ "$output" == *"Preflight complete"* ]]
}

@test "pre-destroy runs the sweep BEFORE anything that removes pods" {
  # Ordering is the whole fix. If the sweep ran after the Karpenter NodePool
  # delete or the LoadBalancer Service delete, the backing pods would already
  # be going away and the sweep would be racing the thing it prevents.
  local pre="$REPO_ROOT/bootstrap/eks/gibson/scripts/eks-pre-destroy.sh"
  local code sweep_line karp_line lb_line
  # Match EXECUTABLE lines only. Matching raw text would let a comment that
  # merely mentions the sweep satisfy the ordering assertion — the failure mode
  # this repo already knows as "guards matched by rendered comments". Blanking
  # comments (rather than dropping them) keeps line numbers comparable.
  code="$BATS_TEST_TMPDIR/pre-destroy.nocomments"
  sed 's/^[[:space:]]*#.*$//' "$pre" > "$code"

  sweep_line=$(grep -n 'eks-sweep-admission-webhooks\.sh' "$code" | head -1 | cut -d: -f1)
  karp_line=$(grep -n 'kubectl delete nodepool' "$code" | head -1 | cut -d: -f1)
  lb_line=$(grep -n 'kubectl delete svc' "$code" | head -1 | cut -d: -f1)
  [ -n "$sweep_line" ]
  [ -n "$karp_line" ]
  [ -n "$lb_line" ]
  [ "$sweep_line" -lt "$karp_line" ]
  [ "$sweep_line" -lt "$lb_line" ]
}
