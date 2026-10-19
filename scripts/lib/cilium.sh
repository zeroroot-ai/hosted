# shellcheck shell=bash
# ---------------------------------------------------------------------------
# cilium.sh — Cilium is the network plugin of every cluster (hosted#436,
# ADR-0083).
#
# It is SOURCED. The caller exports KUBECONFIG and has helm and kubectl on
# PATH. Each function returns non-zero on a failure and prints the cause, so
# the caller decides how to stop.
#
#   cilium_version             print the one pinned version
#   cilium_install <flavor> [helm args]   install the chart with the values
#                              of a flavor, and any extra --set of the caller
#   cilium_verify              the CRD exists and each agent is ready
#   cilium_prove_fqdn_policy   one policy with a host name permits one
#                              connection and refuses one
#
# The pin is bootstrap/cilium/VERSION. scripts/check-cilium-pin.py fails when
# a second pin in the repo differs.
#
# A flavor is a file bootstrap/cilium/values-<flavor>.yaml. A flavor with no
# file uses the shared values only.
# ---------------------------------------------------------------------------

_CILIUM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CILIUM_DIR="${CILIUM_DIR:-$(cd "$_CILIUM_LIB_DIR/../.." && pwd)/bootstrap/cilium}"
CILIUM_CHART="${CILIUM_CHART:-oci://quay.io/cilium/charts/cilium}"
CILIUM_TIMEOUT="${CILIUM_TIMEOUT:-10m}"
# The image of the proof pod. It is the mirror image that cluster-k3d.sh
# already uses.
CILIUM_PROOF_IMAGE="${CILIUM_PROOF_IMAGE:-ghcr.io/zeroroot-ai/mirror/curl:8.10.1}"
# Both hosts answer on 443 from each cluster that pulls its images. So a
# refused connection to the second host is the policy, not the network.
CILIUM_PROOF_ALLOWED_HOST="${CILIUM_PROOF_ALLOWED_HOST:-ghcr.io}"
CILIUM_PROOF_REFUSED_HOST="${CILIUM_PROOF_REFUSED_HOST:-quay.io}"

cilium_version() {
  local v
  v="$(tr -d '[:space:]' < "$CILIUM_DIR/VERSION" 2>/dev/null)"
  case "$v" in
    [0-9]*.[0-9]*.[0-9]*) printf '%s\n' "$v" ;;
    *) echo "cilium: $CILIUM_DIR/VERSION holds no version" >&2; return 1 ;;
  esac
}

cilium_install() {
  local flavor="${1:-}" version
  shift || true
  local -a values
  version="$(cilium_version)" || return 1
  [ -s "$CILIUM_DIR/values.yaml" ] \
    || { echo "cilium: no shared values at $CILIUM_DIR/values.yaml" >&2; return 1; }
  values=( -f "$CILIUM_DIR/values.yaml" )
  if [ -n "$flavor" ] && [ -s "$CILIUM_DIR/values-${flavor}.yaml" ]; then
    values+=( -f "$CILIUM_DIR/values-${flavor}.yaml" )
  fi
  helm upgrade --install cilium "$CILIUM_CHART" \
    --version "$version" --namespace kube-system \
    "${values[@]}" "$@" --wait --timeout "$CILIUM_TIMEOUT" \
    || { echo "cilium: the chart ${version} did not install" >&2; return 1; }
}

cilium_verify() {
  local desired ready reject
  kubectl get crd ciliumnetworkpolicies.cilium.io >/dev/null 2>&1 \
    || { echo "cilium: the CiliumNetworkPolicy CRD is absent. This cluster does not run Cilium, and the substrate contract requires it (ADR-0083)" >&2; return 1; }
  kubectl -n kube-system rollout status daemonset/cilium --timeout="${CILIUM_READY_TIMEOUT:-300s}" >/dev/null 2>&1 \
    || { echo "cilium: the agent DaemonSet kube-system/cilium is not ready" >&2
         kubectl -n kube-system get pods -l k8s-app=cilium -o wide >&2 2>/dev/null || true
         return 1; }
  # A DaemonSet that selects no node reports a finished rollout. That is not
  # a ready agent. rollout status can also return before the status counts
  # are filled, or while an agent restarts once after its first start: signup
  # run 38347993006 read "0 of 1 agents are ready" one second after a
  # finished rollout. So the count is polled, within the same timeout.
  local deadline=$(( $(date +%s) + ${CILIUM_AGENTS_READY_SECONDS:-300} ))
  while :; do
    desired="$(kubectl -n kube-system get daemonset cilium -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)"
    ready="$(kubectl -n kube-system get daemonset cilium -o jsonpath='{.status.numberReady}' 2>/dev/null)"
    if [ -n "$desired" ] && [ "$desired" -ge 1 ] && [ "$ready" = "$desired" ]; then
      break
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "cilium: ${ready:-0} of ${desired:-0} agents are ready" >&2
      kubectl -n kube-system get pods -l k8s-app=cilium -o wide >&2 2>/dev/null || true
      return 1
    fi
    sleep "${CILIUM_AGENTS_POLL_SECONDS:-5}"
  done
  # A denied lookup must answer NXDOMAIN (bootstrap/cilium/values.yaml,
  # charts#518). With REFUSED a resolver stops at the first search domain that
  # the policy does not permit, and no outside host of an egress group resolves.
  reject="$(kubectl -n kube-system get configmap cilium-config \
              -o jsonpath='{.data.tofqdns-dns-reject-response-code}' 2>/dev/null)"
  if [ "$reject" != "nameError" ]; then
    echo "cilium: the DNS proxy answers a denied lookup with '${reject:-refused}', not nameError. Set dnsProxy.dnsRejectResponseCode=nameError (bootstrap/cilium/values.yaml)" >&2
    return 1
  fi
  printf '  ✓ Cilium: the CiliumNetworkPolicy CRD exists, %s of %s agents are ready, and a denied lookup answers NXDOMAIN\n' "$ready" "$desired"
}

# One policy with a host name. The pod reaches the permitted host and does
# not reach the other host. The namespace is the proof's own and it is
# deleted at the end.
cilium_prove_fqdn_policy() {
  local ns="cilium-proof" pod="cilium-proof" rc code deadline
  _cilium_proof_cleanup() { kubectl delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }

  kubectl -n kube-system rollout status deployment/coredns --timeout=300s >/dev/null 2>&1 \
    || { echo "cilium proof: CoreDNS is not ready, so no host name resolves" >&2; return 1; }

  kubectl delete namespace "$ns" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
  kubectl create namespace "$ns" >/dev/null \
    || { echo "cilium proof: could not create the namespace ${ns}" >&2; return 1; }

  kubectl apply -f - >/dev/null <<YAML || { echo "cilium proof: the API refused the CiliumNetworkPolicy" >&2; _cilium_proof_cleanup; return 1; }
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: one-host
  namespace: ${ns}
spec:
  endpointSelector:
    matchLabels:
      app: ${pod}
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*"
    - toFQDNs:
        - matchName: ${CILIUM_PROOF_ALLOWED_HOST}
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
YAML

  kubectl -n "$ns" run "$pod" --image="$CILIUM_PROOF_IMAGE" --labels="app=${pod}" \
    --restart=Never --command -- sleep 900 >/dev/null \
    || { echo "cilium proof: could not start the pod" >&2; _cilium_proof_cleanup; return 1; }
  kubectl -n "$ns" wait --for=condition=Ready "pod/${pod}" --timeout=240s >/dev/null 2>&1 \
    || { echo "cilium proof: the pod did not get ready" >&2
         kubectl -n "$ns" describe "pod/${pod}" >&2 2>/dev/null | tail -20 || true
         _cilium_proof_cleanup; return 1; }

  # The permitted connection. The agent can need a moment to load the policy
  # for a new pod, so the call has a deadline and not one attempt.
  deadline=$(( $(date +%s) + 90 ))
  code=""
  while :; do
    code="$(kubectl -n "$ns" exec "$pod" -- curl -sS -o /dev/null -w '%{http_code}' \
              --connect-timeout 8 --max-time 15 "https://${CILIUM_PROOF_ALLOWED_HOST}/" 2>/dev/null || true)"
    case "$code" in [1-5][0-9][0-9]) break ;; esac
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 5
  done
  case "$code" in
    [1-5][0-9][0-9]) ;;
    *) echo "cilium proof: the policy permits ${CILIUM_PROOF_ALLOWED_HOST}, but the pod could not connect (answer '${code:-none}')" >&2
       _cilium_proof_cleanup; return 1 ;;
  esac

  # The refused connection. curl exits 28 when the connection gets no answer,
  # which is what a dropped packet looks like. Any other result is a failure:
  # exit 0 means the policy did not apply, and exit 6 means DNS failed, so
  # the test did not look at the policy.
  rc=0
  kubectl -n "$ns" exec "$pod" -- curl -sS -o /dev/null \
    --connect-timeout 8 --max-time 10 "https://${CILIUM_PROOF_REFUSED_HOST}/" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 28 ]; then
    echo "cilium proof: the policy does not permit ${CILIUM_PROOF_REFUSED_HOST}, and curl exited ${rc}, not 28 (a refused connection). Cilium does not enforce the host name policy" >&2
    _cilium_proof_cleanup; return 1
  fi

  _cilium_proof_cleanup
  printf '  ✓ Cilium: the policy permits %s (HTTP %s) and refuses %s\n' \
    "$CILIUM_PROOF_ALLOWED_HOST" "$code" "$CILIUM_PROOF_REFUSED_HOST"
}
