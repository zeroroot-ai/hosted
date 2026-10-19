# shellcheck shell=bash
# ---------------------------------------------------------------------------
# edge-cert.sh — keep the edge TLS certificate of an environment across
# recreates (row 9 of the drill path audit, coordinator decision of
# 2026-10-12).
#
# Every recreate asked Let's Encrypt for a new edge certificate. The drill
# made five in one day and reached the duplicate-certificate limit (5 per
# exact name set per 7 days); prod and staging recreates burn the same quota.
# cert-manager keeps a Secret that is valid and matches its Certificate, and
# issues nothing. So:
#
#   edge_cert_store     at teardown, before the cluster goes: read the
#                       cert-manager Secret of the edge Certificate and put
#                       it into the env's Secrets Manager secret
#                       (EDGE_CERT_SECRET of substrate.env, stage 0
#                       edge-cert.tf; KMS-encrypted; only the bringup role
#                       reads or writes it).
#   edge_cert_restore   at bringup, before Argo syncs the gibson app, in a
#                       fresh and in a restore recreate alike: write the
#                       stored Secret back, unless it expires within
#                       EDGE_CERT_MIN_DAYS (30) days or its names are not the
#                       names the Certificate asks for. Then cert-manager
#                       issues a new one, as before.
#
# The caller sets: NS (the release namespace), EDGE_CERT_SECRET, and its own
# log() and die(). EDGE_CERT_WANT_NAMES is the space-separated dnsNames of the
# edge Certificate the chart renders; the caller reads it from the render it
# already makes. The certificate and its key never reach a log, a file
# outside a mode-700 directory, or argv.
# ---------------------------------------------------------------------------

EDGE_CERT_K8S_SECRET="${EDGE_CERT_K8S_SECRET:-gibson-envoy-tls}"
EDGE_CERT_MIN_DAYS="${EDGE_CERT_MIN_DAYS:-30}"

# edge_cert_overlay_names <values.yaml> — the dnsNames that the overlay sets
# for the edge Certificate (gibson-workloads.certManager.envoyEdge.dnsNames),
# space-separated. Empty when the overlay leaves them to the chart default:
# then edge_cert_restore does not know the names and restores nothing.
edge_cert_overlay_names() {
  python3 - "$1" <<'PY' || die "could not read the edge dnsNames from $1 (PyYAML is required: requirements-ci.txt)"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
edge = ((d.get("gibson-workloads") or {}).get("certManager") or {}).get("envoyEdge") or {}
print(" ".join(edge.get("dnsNames") or []))
PY
}

# _edge_cert_dir — a private scratch directory, removed by the caller's trap.
_edge_cert_dir() {
  local d
  d="$(umask 077 && mktemp -d)" || return 1
  printf '%s' "$d"
}

# edge_cert_store — copy the edge Secret of the cluster into the env secret.
# A cluster with no edge Secret yet (a bringup that never issued) stores
# nothing and says so; that is not an error.
edge_cert_store() {
  [ -n "${EDGE_CERT_SECRET:-}" ] || die "EDGE_CERT_SECRET is not set: stage 0 (edge-cert.tf) names it in substrate.env"
  local d
  d="$(_edge_cert_dir)" || die "could not make a private directory for the edge certificate"
  if ! kubectl -n "${NS}" get secret "${EDGE_CERT_K8S_SECRET}" -o json > "$d/secret.json" 2>"$d/err"; then
    # Only a Secret that does not exist means nothing to keep. A cluster that
    # does not answer, or a role that cannot read Secrets, stops the
    # teardown: it would destroy the cluster with the certificate unsaved.
    if grep -q 'NotFound' "$d/err"; then
      log "edge certificate: ${NS}/${EDGE_CERT_K8S_SECRET} does not exist, nothing to keep"
      rm -rf "$d"; return 0
    fi
    local why; why="$(head -c 300 "$d/err")"
    rm -rf "$d"
    die "could not read ${NS}/${EDGE_CERT_K8S_SECRET}, so the edge certificate is not kept: ${why}"
  fi
  python3 - "$d/secret.json" > "$d/value.json" <<'PY' || { rm -rf "$d"; die "the edge Secret has no tls.crt or tls.key"; }
import json, sys
s = json.load(open(sys.argv[1]))
data = s.get("data") or {}
if not data.get("tls.crt") or not data.get("tls.key"):
    sys.exit(1)
ann = {k: v for k, v in ((s.get("metadata") or {}).get("annotations") or {}).items()
       if k.startswith("cert-manager.io/")}
print(json.dumps({"tls.crt": data["tls.crt"], "tls.key": data["tls.key"], "annotations": ann}))
PY
  aws secretsmanager put-secret-value --secret-id "${EDGE_CERT_SECRET}" \
      --secret-string "file://$d/value.json" >/dev/null \
    || { rm -rf "$d"; die "could not store the edge certificate in ${EDGE_CERT_SECRET}"; }
  rm -rf "$d"
  log "edge certificate: ${NS}/${EDGE_CERT_K8S_SECRET} kept in ${EDGE_CERT_SECRET}"
}

# edge_cert_restore — write the stored edge Secret back before Argo syncs.
edge_cert_restore() {
  [ -n "${EDGE_CERT_SECRET:-}" ] || die "EDGE_CERT_SECRET is not set: stage 0 (edge-cert.tf) names it in substrate.env"
  local d verdict
  d="$(_edge_cert_dir)" || die "could not make a private directory for the edge certificate"
  if ! aws secretsmanager get-secret-value --secret-id "${EDGE_CERT_SECRET}" \
        --query SecretString --output text > "$d/value.json" 2>"$d/err"; then
    # A secret that has no value yet: the first teardown has not run. AWS
    # says ResourceNotFoundException for this too, so the value case first.
    if grep -qE "can't find the specified secret value" "$d/err"; then
      log "edge certificate: ${EDGE_CERT_SECRET} holds nothing yet; cert-manager issues one"
      rm -rf "$d"; return 0
    fi
    if grep -q 'ResourceNotFoundException' "$d/err"; then
      rm -rf "$d"; die "the secret ${EDGE_CERT_SECRET} does not exist. Run make substrate for this env (edge-cert.tf)"
    fi
    rm -rf "$d"; die "could not read ${EDGE_CERT_SECRET}"
  fi
  verdict="$(EDGE_CERT_WANT_NAMES="${EDGE_CERT_WANT_NAMES:-}" EDGE_CERT_MIN_DAYS="${EDGE_CERT_MIN_DAYS}" \
    python3 - "$d/value.json" "$d/tls.crt" <<'PY'
import base64, json, os, subprocess, sys
v = json.load(open(sys.argv[1]))
crt = base64.b64decode(v["tls.crt"])
open(sys.argv[2], "wb").write(crt)
want = sorted(os.environ.get("EDGE_CERT_WANT_NAMES", "").split())
if not want:
    print("skip: the names the Certificate asks for are unknown"); sys.exit()
days = int(os.environ["EDGE_CERT_MIN_DAYS"])
if subprocess.run(["openssl", "x509", "-noout", "-checkend", str(days * 86400), "-in", sys.argv[2]],
                  capture_output=True).returncode != 0:
    print(f"skip: the stored certificate expires within {days} days"); sys.exit()
out = subprocess.run(["openssl", "x509", "-noout", "-ext", "subjectAltName", "-in", sys.argv[2]],
                     capture_output=True, text=True).stdout
have = sorted(p.strip()[4:] for p in out.replace("\n", ",").split(",") if p.strip().startswith("DNS:"))
if have != want:
    print(f"skip: the stored certificate names {have}, and the Certificate asks for {want}"); sys.exit()
print("restore")
PY
)" || { rm -rf "$d"; die "could not read the stored edge certificate"; }
  case "$verdict" in
    restore) ;;
    *) log "edge certificate: ${verdict#skip: }; cert-manager issues a new one"; rm -rf "$d"; return 0 ;;
  esac
  python3 - "$d/value.json" "${NS}" "${EDGE_CERT_K8S_SECRET}" > "$d/secret.json" <<'PY'
import json, sys
v = json.load(open(sys.argv[1]))
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": "kubernetes.io/tls",
                  "metadata": {"name": sys.argv[3], "namespace": sys.argv[2], "annotations": v.get("annotations") or {}},
                  "data": {"tls.crt": v["tls.crt"], "tls.key": v["tls.key"]}}))
PY
  kubectl apply -f "$d/secret.json" >/dev/null || { rm -rf "$d"; die "could not write ${NS}/${EDGE_CERT_K8S_SECRET}"; }
  rm -rf "$d"
  log "edge certificate: restored ${NS}/${EDGE_CERT_K8S_SECRET} from ${EDGE_CERT_SECRET}; cert-manager keeps it"
}
