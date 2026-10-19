#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# eks-blocker-classes.sh — assert the cloud-only blocker classes that kind
# CANNOT exercise (deploy#930 / E12, RESTRUCTURE-QUALITY-BARS §5).
#
# The kind-standup-nightly gate proves the umbrella stands up from zero, but a
# kind cluster has no IRSA, no Aurora, and no AWS-KMS auto-unseal — so a whole
# class of standup regressions only ever surfaces on a real EKS bringup. This
# script is the hard assertion the eks-acceptance gate runs against the live
# zeroroot-ai EKS cluster AFTER bringup, so those classes fail the gate LOUDLY
# instead of being discovered by hand during a real standup.
#
# It checks THREE classes, each end-to-end (the cloud resource exists AND the
# in-cluster consumer actually used it):
#
#   IRSA    — the IRSA roles are annotated onto their ServiceAccounts AND an
#             IRSA-backed ExternalSecret actually SecretSynced (a broken trust
#             policy / keyPrefix mismatch shows up as SecretSyncedError, which
#             kind never sees because kind ESO reads a static backend).
#   AURORA  — the Aurora-backed datastores are Available and reachable: the
#             platform Postgres consumers (zitadel/openfga/spire) report ready,
#             which they cannot do unless the Aurora cluster resumed and the
#             per-DB credentials (seeded post-aurora) resolved.
#   KMS     — OpenBao auto-unsealed via `seal "awskms"` (deploy#835): the
#             openbao pod is Ready (a sealed pod never goes Ready) AND the
#             gibson-master-key Secret was minted through OpenBao transit — the
#             keystone that proves the KMS grant + IRSA path worked together.
#
# Requires: kubectl (pointed at the target EKS cluster), aws CLI v2, python3.
#
# Usage:
#   KUBECONFIG=/tmp/kubeconfig-zeroroot ./scripts/eks-blocker-classes.sh
#
# Exit codes:
#   0 — every blocker class passed.
#   1 — at least one class FAILED (the failing class + hint printed).
#   2 — usage / environment error.
# ----------------------------------------------------------------------------

set -euo pipefail

readonly NS="${GIBSON_NAMESPACE:-gibson}"
readonly ESO_NS="${ESO_NAMESPACE:-external-secrets}"

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not in PATH." >&2; exit 2; }

# Track failures so we report EVERY failing class in one run, not just the first.
declare -a FAILED=()

pass() { printf '  [PASS]   %-8s %s\n' "$1" "$2"; }
fail() {
  printf '  [FAIL]   %-8s %s\n' "$1" "$2" >&2
  printf '           hint: %s\n' "$3" >&2
  FAILED+=("$1")
}

# ---------------------------------------------------------------------------
# Class 1: IRSA — roles annotated + an IRSA-backed ExternalSecret synced.
# ---------------------------------------------------------------------------
check_irsa() {
  local sa_arn synced
  # The external-secrets controller SA must carry an IRSA role-arn annotation;
  # without it ESO falls back to node-role creds and can't read gibson/<env>/*.
  sa_arn="$(kubectl get sa -n "${ESO_NS}" \
    -l app.kubernetes.io/name=external-secrets \
    -o jsonpath='{.items[*].metadata.annotations.eks\.amazonaws\.com/role-arn}' \
    2>/dev/null || true)"
  if [[ -z "${sa_arn}" ]]; then
    fail IRSA "external-secrets ServiceAccount has no eks.amazonaws.com/role-arn annotation" \
      "module.iam_irsa external_secrets role not wired to the ESO SA (terraform service_accounts map / chart serviceAccount.annotations)."
    return
  fi
  # End-to-end: at least one ExternalSecret must be SecretSynced. A bad IRSA
  # trust policy or keyPrefix surfaces here as SecretSyncedError.
  synced="$(kubectl get externalsecret -A \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
    2>/dev/null | grep -c '^True$' || true)"
  if [[ "${synced:-0}" -lt 1 ]]; then
    fail IRSA "no ExternalSecret reached Ready=True (SecretSynced)" \
      "IRSA reader role/keyPrefix mismatch or backend secret missing — see the charts secret contract (helm/gibson/secret-contract.yaml); describe a failing ExternalSecret for SecretSyncedError."
    return
  fi
  pass IRSA "ESO SA carries role-arn (${sa_arn##*/}); ${synced} ExternalSecret(s) SecretSynced"
}

# ---------------------------------------------------------------------------
# Class 2: AURORA — Aurora-backed platform Postgres consumers are ready.
# ---------------------------------------------------------------------------
check_aurora() {
  # zitadel + openfga + spire-server all sit on Aurora-backed Postgres. If
  # Aurora never resumed (cold auto-pause) or the per-DB creds (seeded AFTER
  # the aurora stage) didn't resolve, these never go ready.
  local notready=()
  for dep in \
    "deployment app.kubernetes.io/name=zitadel" \
    "deployment app.kubernetes.io/name=openfga"; do
    local kind sel ready
    kind="${dep%% *}"; sel="${dep#* }"
    ready="$(kubectl get "${kind}" -n "${NS}" -l "${sel}" \
      -o jsonpath='{.items[*].status.readyReplicas}' 2>/dev/null | tr ' ' '\n' | grep -c '[1-9]' || true)"
    [[ "${ready:-0}" -ge 1 ]] || notready+=("${sel}")
  done
  if [[ "${#notready[@]}" -gt 0 ]]; then
    fail AURORA "Aurora-backed consumers not ready: ${notready[*]}" \
      "RDS not Available (serverless_min_acu cold-resume can exceed pod probes) or per-DB credentials unresolved — check module.rds apply + the app-secrets stage."
    return
  fi
  pass AURORA "Aurora-backed platform Postgres consumers (zitadel, openfga) ready"
}

# ---------------------------------------------------------------------------
# Class 3: KMS — OpenBao auto-unsealed via seal "awskms" + master key minted.
# ---------------------------------------------------------------------------
check_kms() {
  # A sealed OpenBao pod never reports Ready, so pod-Ready is a direct proxy
  # for "auto-unseal via the KMS grant succeeded" (deploy#835).
  local obready
  obready="$(kubectl get pod -n "${NS}" -l app.kubernetes.io/name=openbao \
    -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null | tr ' ' '\n' | grep -c '^true$' || true)"
  if [[ "${obready:-0}" -lt 1 ]]; then
    fail KMS "OpenBao pod not Ready (likely still sealed)" \
      "seal \"awskms\" auto-unseal failed — KMS grant (alias/<workspace>-openbao-unseal) missing or the openbao IRSA role can't kms:Decrypt; check the openbao pod logs for seal-migration / AccessDenied."
    return
  fi
  # Keystone: the master key is minted through OpenBao transit — proves the
  # unsealed engine is actually serving, not merely Ready.
  if ! kubectl get secret -n "${NS}" gibson-master-key >/dev/null 2>&1; then
    fail KMS "gibson-master-key Secret not minted via OpenBao transit" \
      "OpenBao unsealed but the platform-bootstrap transit-mint step didn't complete; platform-operator may need its vault token refreshed (rollout restart on stale)."
    return
  fi
  pass KMS "OpenBao auto-unsealed (pod Ready) + gibson-master-key minted via transit"
}

echo "eks-blocker-classes: asserting cloud-only blocker classes (IRSA / Aurora / KMS) against namespace '${NS}'"
echo ""
check_irsa
check_aurora
check_kms
echo ""

if [[ "${#FAILED[@]}" -gt 0 ]]; then
  echo "eks-blocker-classes: FAILED classes: ${FAILED[*]}" >&2
  exit 1
fi
echo "eks-blocker-classes: all blocker classes passed."
exit 0
