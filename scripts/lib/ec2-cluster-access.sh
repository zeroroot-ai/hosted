#!/usr/bin/env bash
# ec2-cluster-access.sh — the one way to reach a cluster whose stage 1 is an
# EC2 instance running k3s (ADR-0095).
#
# The instance publishes no API port: `api_allow_cidrs = []` in every
# environment's tfvars, so the security group opens 80 and 443 and nothing
# else. An operator with no AWS credential reaches nothing. Reaching the API
# therefore means three steps, in this order, and getting any of them wrong
# fails much later as an unreadable certificate or a hang:
#
#   1. read the kubeconfig off the instance over SSM
#   2. rewrite its server to 127.0.0.1:<port>
#   3. open an SSM port forward on that port, and wait for the API to answer
#
# This file existed as two copies, one in scripts/recreate-ec2.sh and one in
# scripts/teardown-ec2.sh, which had already drifted: the recreate read the
# kubeconfig through its own ssm_run helper and the teardown inlined the
# send-command poll. ADR-0095 needs a THIRD caller, a verb that connects to a
# cluster that is already up without recreating it, and a third copy of a
# drifting pair is how the next reader learns the wrong one. So: one copy.
#
# Source this file, then call the functions. The caller supplies:
#
#   AWS_REGION       the region the instance is in
#   API_LOCAL_PORT   the local port the forward binds (default 6443)
#   die()            MUST exit non-zero
#
# and sources scripts/lib/ssm-forward.sh, which owns the forward's lifetime.

# ec2_ssm_run <instance-id> <command> — run one shell command on the instance
# and print its stdout. Non-zero when SSM never reports Success.
ec2_ssm_run() {
  local id_arg="$1" cmd="$2" cid status out
  cid="$(aws ssm send-command --instance-ids "$id_arg" --region "$AWS_REGION" \
         --document-name AWS-RunShellScript \
         --parameters "commands=[$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$cmd")]" \
         --query 'Command.CommandId' --output text 2>/dev/null)" || return 1
  for _ in $(seq 1 60); do
    status="$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$id_arg" \
              --region "$AWS_REGION" --query Status --output text 2>/dev/null || echo Pending)"
    case "$status" in
      Success) break ;;
      Failed|Cancelled|TimedOut) return 1 ;;
    esac
    sleep 5
  done
  [ "$status" = Success ] || return 1
  out="$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$id_arg" \
         --region "$AWS_REGION" --query StandardOutputContent --output text 2>/dev/null)" || return 1
  [ -n "$out" ] && [ "$out" != None ] || return 1
  printf '%s' "$out"
}

# ec2_cluster_connect <instance-id> <kubeconfig-path> — steps 1 to 3. On
# success the kubeconfig at that path reaches the API through the forward, and
# the caller's own ssm_forward_stop trap tears the forward down.
ec2_cluster_connect() {
  local id_arg="$1" kc="$2"
  [ -n "$id_arg" ] || return 1
  ec2_ssm_run "$id_arg" 'cat /var/lib/rancher/k3s/server/kubeconfig-external.yaml' > "$kc" || return 1
  [ -s "$kc" ] || return 1
  chmod 0600 "$kc"
  # The address k3s wrote is the one this run cannot use. Rewriting it is not
  # cosmetic: a kubeconfig that still names the node makes kubectl dial an
  # address the security group refuses, and the error names TLS, not the port.
  python3 - "$kc" "$API_LOCAL_PORT" <<'PY' || return 1
import re, sys
p, port = sys.argv[1], sys.argv[2]
s = open(p).read()
open(p, "w").write(re.sub(r"server: https://[^\s]+", f"server: https://127.0.0.1:{port}", s))
PY
  ssm_forward_start "$id_arg" "$AWS_REGION" "$API_LOCAL_PORT" || return 1
  export KUBECONFIG="$kc"
  # kubectl exec, attach and cp use SPDY, not WebSocket. The WebSocket
  # transport of kubectl drops stream bytes, and the exec still exits 0: the
  # stdin of `exec -i` arrived empty (drill runs 39171920065 and 39175834377,
  # a canary marker of 0 bytes four times in a row), and stdout was lost on
  # kind, with no forward at all ("Unknown stream id 1, discarding message",
  # #253). The Makefile exports the same value for each verb. This line is
  # for the EC2 callers that do not run through make (drill-rotate-keys.sh
  # runs with-cluster.sh directly). Many callers send a password or a token
  # on stdin, and a secret must not move to argv. A tool that links
  # client-go and opens its own exec stream does not read this variable.
  # docs/kubectl-transport.md lists each tool of this repository and says
  # which opens one (none today).
  export KUBECTL_REMOTE_COMMAND_WEBSOCKETS=false
  local deadline; deadline=$(( $(date +%s) + 120 ))
  until kubectl cluster-info >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 3
  done
  return 0
}
