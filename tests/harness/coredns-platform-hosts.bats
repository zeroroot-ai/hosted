#!/usr/bin/env bats
#
# coredns-platform-hosts.bats — each bringup maps the platform's public hosts to
# the Envoy Service in CoreDNS (hosted#397).
#
# Offline, by construction: the Corefile rewrite and the domain reader are
# pure functions over text, so a stale record, a doubled block or a missing
# domain fail here, on every PR, and not in a sandboxed agent's log twenty
# minutes into a bring-up.
#
# Run:
#   bats tests/harness/coredns-platform-hosts.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  # shellcheck source=scripts/lib/coredns-platform-hosts.sh
  . "$REPO_ROOT/scripts/lib/coredns-platform-hosts.sh"
  SVC=gibson-envoy.gibson.svc.cluster.local
  # The Corefile kind ships, verbatim in shape.
  COREFILE='.:53 {
    errors
    health {
       lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    forward . /etc/resolv.conf {
       max_concurrent 1000
    }
    cache 30
    loop
    reload
    loadbalance
}
'
}

@test "the record lands inside the .:53 server block, ahead of kubernetes, and names the Service" {
  run corefile_with_platform_hosts "$COREFILE" "$SVC" api.localhost.zeroroot.ai app.localhost.zeroroot.ai
  [ "$status" -eq 0 ]
  [[ "$output" == *"rewrite name exact api.localhost.zeroroot.ai gibson-envoy.gibson.svc.cluster.local answer auto"* ]]
  [[ "$output" == *"rewrite name exact app.localhost.zeroroot.ai gibson-envoy.gibson.svc.cluster.local answer auto"* ]]
  local pos_server pos_rule pos_k8s
  pos_server="$(printf '%s' "$output" | grep -n '^\.:53 {' | cut -d: -f1)"
  pos_rule="$(printf '%s' "$output" | grep -n '^    rewrite name exact api' | cut -d: -f1)"
  pos_k8s="$(printf '%s' "$output" | grep -n '^    kubernetes ' | cut -d: -f1)"
  [ "$pos_server" -lt "$pos_rule" ]
  [ "$pos_rule" -lt "$pos_k8s" ]
  # Everything the cluster shipped is still there.
  [[ "$output" == *"forward . /etc/resolv.conf"* ]]
  [[ "$output" == *"loadbalance"* ]]
}

@test "the record holds no address: the host follows the Service wherever it is" {
  run corefile_with_platform_hosts "$COREFILE" "$SVC" api.localhost.zeroroot.ai
  [ "$status" -eq 0 ]
  run bash -c 'printf "%s" "$1" | sed -n "/BEGIN platform hosts/,/END platform hosts/p" | grep -cE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' _ "$output"
  [ "$output" = "0" ]
}

@test "a second bringup replaces the block instead of doubling it" {
  first="$(corefile_with_platform_hosts "$COREFILE" "$SVC" api.localhost.zeroroot.ai)"
  run corefile_with_platform_hosts "$first" "$SVC" api.other.example.com
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -c 'BEGIN platform hosts')" -eq 1 ]
  [[ "$output" == *"rewrite name exact api.other.example.com"* ]]
  [[ "$output" != *"api.localhost.zeroroot.ai"* ]]
}

@test "FAILING FIXTURE: an address as the target is refused (hosted#186)" {
  run corefile_with_platform_hosts "$COREFILE" 10.96.0.250 api.localhost.zeroroot.ai
  [ "$status" -eq 2 ]
  [[ "$output" == *"is an address"* ]]
}

@test "FAILING FIXTURE: a target that is not a Service name is refused" {
  run platform_host_rules envoy.example.com api.localhost.zeroroot.ai
  [ "$status" -eq 2 ]
  [[ "$output" == *"is not <service>.<namespace>.svc.cluster.local"* ]]
}

@test "FAILING FIXTURE: a Corefile with no .:53 server block is refused, never guessed" {
  run corefile_with_platform_hosts 'example.org:53 {
    whoami
}
' "$SVC" api.localhost.zeroroot.ai
  [ "$status" -eq 2 ]
  [[ "$output" == *"no \`.:53 {\` server block"* ]]
}

@test "FAILING FIXTURE: no host is refused" {
  run corefile_with_platform_hosts "$COREFILE" "$SVC"
  [ "$status" -eq 2 ]
}

@test "the k3s form is the same rules with no server block around them" {
  run platform_host_rules "$SVC" api.staging.zeroroot.ai app.staging.zeroroot.ai
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "rewrite name exact api.staging.zeroroot.ai gibson-envoy.gibson.svc.cluster.local answer auto" ]
}

@test "the domain comes from the values files in install order, last wins" {
  printf 'gibson-workloads:\n  global:\n    domain: "localhost.zeroroot.ai"\n' > "$BATS_TEST_TMPDIR/baseline.yaml"
  printf 'gibson-workloads:\n  resources: {}\n' > "$BATS_TEST_TMPDIR/rung.yaml"
  printf 'global:\n  domain: "dev.example.test"\n' > "$BATS_TEST_TMPDIR/extra.yaml"
  run values_domain "$BATS_TEST_TMPDIR/baseline.yaml" "$BATS_TEST_TMPDIR/rung.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "localhost.zeroroot.ai" ]
  run values_domain "$BATS_TEST_TMPDIR/baseline.yaml" "$BATS_TEST_TMPDIR/rung.yaml" "$BATS_TEST_TMPDIR/extra.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "dev.example.test" ]
}

@test "FAILING FIXTURE: values that name no domain are refused" {
  printf 'gibson-workloads:\n  resources: {}\n' > "$BATS_TEST_TMPDIR/rung.yaml"
  run values_domain "$BATS_TEST_TMPDIR/rung.yaml"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no values file names global.domain"* ]]
}

@test "the live baseline profile names a domain the record can follow" {
  [ -s "${CHARTS_ROOT:-$REPO_ROOT/../charts}/helm/gibson/values-baseline.yaml" ] || skip "no charts checkout at CHARTS_ROOT"
  run values_domain "${CHARTS_ROOT:-$REPO_ROOT/../charts}/helm/gibson/values-baseline.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *.* ]]
}
