#!/usr/bin/env bats
#
# nlb-security-group.bats: test/edge/assert-nlb-security-group.sh fails when
# the NLB of the EKS edge has no security group of its own, or when no target
# admits it by reference (hosted#508). Offline: aws and kubectl are stubs that
# answer each call with the already-filtered result the real query returns.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
CHECK="$REPO_ROOT/test/edge/assert-nlb-security-group.sh"

setup() {
  STUBS="$BATS_TEST_TMPDIR/bin"; mkdir -p "$STUBS"
  # The stub answers only the edge Service the check reads (hosted#654).
  cat > "$STUBS/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "-n gibson get svc gibson-envoy -o jsonpath={.status.loadBalancer.ingress[0].hostname}")
    printf '%s' "${STUB_HOST-nlb-1.elb.us-east-1.amazonaws.com}"; exit 0 ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
STUB
  cat > "$STUBS/aws" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"describe-load-balancers"*)
    printf '{"LoadBalancerArn":"arn:lb/1","SecurityGroups":%s}' "${STUB_NLB_SGS-[\"sg-nlb\"]}" ;;
  *"describe-target-groups"*) printf '%s' "${STUB_TGS-arn:tg/1}" ;;
  *"describe-target-health"*) printf '%s' "${STUB_TARGETS-10.0.1.5}" ;;
  *"describe-network-interfaces"*) printf '%s' "${STUB_TARGET_SGS-sg-node}" ;;
  *"describe-security-groups"*) printf '%s' "${STUB_REFERENCING-sg-node}" ;;
esac
STUB
  chmod +x "$STUBS/kubectl" "$STUBS/aws"
  export PATH="$STUBS:$PATH"
}

@test "an NLB with its own security group that each target admits by reference passes" {
  run bash "$CHECK"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: the NLB has its own security group, and 1 target(s) admit it by reference"* ]]
}

@test "FAILING FIXTURE: an NLB with no security group fails" {
  STUB_NLB_SGS='[]' run bash "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no security group of its own"* ]]
}

@test "FAILING FIXTURE: a target whose security groups do not reference the NLB group fails" {
  STUB_REFERENCING='' run bash "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"none admits the NLB security group sg-nlb by reference"* ]]
}

@test "FAILING FIXTURE: target groups with no target fail, they never pass empty" {
  STUB_TARGETS='' run bash "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"hold no target"* ]]
}

@test "FAILING FIXTURE: a Service with no load-balancer hostname fails" {
  STUB_HOST='' run bash "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no load-balancer hostname"* ]]
}
