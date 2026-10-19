#!/usr/bin/env bash
# substrate.sh — stage 0, the substrate bootstrap, for ENV=kind (ADR-0083, deploy#1736).
#
# Stage 0 is the only part of an environment that outlives its cluster, so on
# kind it cannot run inside the cluster. It runs as three Docker containers
# on the host, attached to the `kind` Docker network with pinned addresses,
# so pods and the workstation reach them at the same address:
#
#   substrate-kind-minio     the durable bucket (S3 API on :9000, console on :9001)
#   substrate-kind-coredns   the DNS sub-zone kind.zeroroot.test (:53)
#   substrate-kind-registry  the setec disk registry (OCI on :5000, D85)
#
# Stage 0 for kind makes no SMTP relay (hosted#126). The daemon sends mail
# with Go net/smtp, and that client refuses AUTH PLAIN over a connection
# without TLS to any host but localhost. A relay on the kind network with
# AUTH and no TLS was therefore unusable. The kind mail path is the
# in-cluster Mailpit sink of the chart, with no AUTH (test/signup/values.yaml).
# So substrate.env for kind has no SMTP rows, and preflight line 5 prints
# as skipped on kind.
#
# Everything durable lives under one state directory OUTSIDE the checkout
# (the Makefile passes SUBSTRATE_DIR/kind, default /bulk/substrate/kind),
# for the same reason KIND_PV_DIR does: it must survive a reboot, a deleted
# worktree and every `kind delete cluster`:
#
#   keyring.env      the bringup keyring (scripts/keyring.sh), mode 0600
#   substrate.env    what preflight reads: endpoints, names, fingerprints, no secrets
#   minio-root.env   the MinIO admin credential. Stage 0's own, never the platform's
#   minio/ coredns/  container data
#   registry/        the signed setec sandbox disks
#
# The bucket gets the three properties preflight proves: versioning on, a
# platform credential (from the keyring) whose only delete is s3:DeleteObject
# under backups/velero/ (kopia's requirement, deploy#1734), and one enabled
# lifecycle rule per prefix. The MinIO admin credential configures it and is
# never written to substrate.env or the keyring.
#
# Idempotent: a second run changes nothing and rewrites substrate.env with
# the same values. A container whose run configuration differs from what
# this file would start it with (image, address, arguments, the CONTENT of
# its env-file) is recreated on its existing data: scripts/lib/ensure-container.sh
# keys each container by a fingerprint label. A container reads its
# --env-file once, at `docker run`, so comparing only the image and the
# address left stale credentials running after the state directory was
# regenerated (2026-09-05).
#
# Usage: substrate.sh <state-dir>        (make substrate ENV=kind calls it)

set -euo pipefail

STATE="${1:-}"
[ -n "$STATE" ] || { echo "usage: substrate.sh <state-dir>" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# bootstrap/kind/substrate -> repo root is three levels up. It was two until the
# 2026-09-04 split (ADR-0086) moved kind/ under bootstrap/, and nothing updated
# this line, so every caller resolved scripts/ under bootstrap/ and died.
REPO="$(cd "$HERE/../../.." && pwd)"
KEYRING="$REPO/scripts/keyring.sh"

NET=kind
ZONE=kind.zeroroot.test
BUCKET=gibson-kind
REGION=us-east-1
PLATFORM_POLICY=gibson-platform

# Mirrored images only (scripts/check-image-registry.py explains why).
MINIO_IMAGE=ghcr.io/zeroroot-ai/mirror/minio:RELEASE.2024-09-13T20-26-02Z
COREDNS_IMAGE=ghcr.io/zeroroot-ai/mirror/coredns:1.14.7
# The setec exit test of setec pins the same digest (exit-test-launcher.yml).
REGISTRY_IMAGE=ghcr.io/zeroroot-ai/mirror/registry:2@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373
DISK_REPO_NAME=setec-disks

C_MINIO=substrate-kind-minio
C_DNS=substrate-kind-coredns
C_REGISTRY=substrate-kind-registry

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; NC=$'\033[0m'
say()  { printf '%s  ✓%s [substrate] %s\n' "$GREEN" "$NC" "$*"; }
step() { printf '%s▶%s [substrate] %s\n' "$GREEN" "$NC" "$*"; }
die()  { printf '%s!%s [substrate] %s\n' "$RED" "$NC" "$*" >&2; exit 2; }

for tool in docker dig python3; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"
done
docker info >/dev/null 2>&1 || die "docker is installed but the daemon is not reachable"
[ -x "$KEYRING" ] || die "$KEYRING is missing"

umask 077
mkdir -p "$STATE"/minio "$STATE"/coredns "$STATE"/registry
chmod 0700 "$STATE"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# The kind Docker network. kind creates it on the first cluster and never
# deletes it. On a workstation that has not run kind yet, create it the way
# kind does (bridge, masquerade, the IPv6 ULA kind derives for the name
# "kind"), so the first cluster adopts it unchanged.
# ---------------------------------------------------------------------------
step "network $NET"
if ! docker network inspect "$NET" >/dev/null 2>&1; then
  # The IPv4 subnet MUST be given explicitly. Docker refuses a static --ip on a
  # network whose subnet it chose itself ("user specified IP address is
  # supported only when connecting to networks with user configured subnets"),
  # and stage 0 pins three addresses. Creating with the IPv6 ULA alone left
  # IPv4 auto-assigned, which worked on a workstation (where kind had already
  # made the network with an explicit subnet) and failed on every fresh CI
  # runner (exit-test-vanilla-install run 33549240795). Take the first free
  # /16 in the range kind itself picks from, so the first cluster adopts the
  # network unchanged.
  net_created=0
  for octet in 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
    if docker network create -d bridge \
        -o com.docker.network.bridge.enable_ip_masquerade=true \
        --subnet "172.${octet}.0.0/16" --gateway "172.${octet}.0.1" \
        --ipv6 --subnet fc00:f853:ccd:e793::/64 "$NET" >/dev/null 2>&1; then
      net_created=1
      say "created Docker network $NET on 172.${octet}.0.0/16"
      break
    fi
  done
  [ "$net_created" = 1 ] || die "could not create Docker network $NET: every /16 from 172.18 to 172.31 overlaps an existing network. Free one and re-run."
fi
SUBNET="$(docker network inspect "$NET" -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' | grep -E '^[0-9]+\.' | head -n1)"
[ -n "$SUBNET" ] || die "Docker network $NET has no IPv4 subnet"
# Addresses near the top of the subnet, far above anything Docker hands
# out dynamically, pinned so substrate.env stays stable across restarts.
read -r MINIO_IP REGISTRY_IP DNS_IP < <(python3 -c '
import ipaddress, sys
n = ipaddress.ip_network(sys.argv[1])
print(n[-6], n[-5], n[-4])' "$SUBNET")
say "subnet $SUBNET: minio $MINIO_IP, registry $REGISTRY_IP, coredns $DNS_IP"

# ---------------------------------------------------------------------------
# Keyring and stage 0's own credentials. Generated once, then reused.
# ---------------------------------------------------------------------------
step "keyring"
if [ -f "$STATE/keyring.env" ]; then
  say "keyring present at $STATE/keyring.env"
else
  "$KEYRING" generate "$STATE/keyring.env"
fi

# The INPUT member (deploy#1732): the one seed value the platform cannot
# generate. Refreshed on every run, because a GitHub token rotates. Sources,
# in order: the environment (GHCR_PULL_TOKEN), then `gh auth token`. Nothing
# found leaves the member as it is: empty on a fresh keyring, which the
# sidecar seeds as "not supplied". Empty is allowed.
#
# LLM_KEYS_JSON USED TO BE THE SECOND ONE and is gone. There is no platform
# LLM credential: the daemon takes LLM keys from the tenant provider resolver
# through the secrets broker, and an environment key counts only under
# GIBSON_DEV_ENV_FALLBACK. Removing the member from scripts/keyring.sh left
# this writer behind, so `make substrate ENV=kind` failed outright on a
# workstation that happens to have ~/.anthropic.tok:
#
#   keyring: LLM_KEYS_JSON is not an input member; only GHCR_PULL_TOKEN,
#   DNS_ACCESS_KEY, DNS_SECRET_KEY and GITHUB_APP_PRIVATE_KEY may be set
#
# It read three token files off the developer's home directory and put them in
# the platform's keyring, which is exactly the shape the removal was meant to
# end. Measured 2026-09-15 on the first from-nothing run after the removal.
ghcr_token="${GHCR_PULL_TOKEN-}"
if [ -z "$ghcr_token" ] && command -v gh >/dev/null 2>&1; then
  ghcr_token="$(gh auth token 2>/dev/null || true)"
fi
if [ -n "$ghcr_token" ]; then
  "$KEYRING" set "$STATE/keyring.env" GHCR_PULL_TOKEN "$ghcr_token"
else
  say "GHCR_PULL_TOKEN not supplied: the platform seeds ghcr-pull-secret empty (scripts/baseline-set-secret.sh fills it)"
fi
ghcr_token=""
BUCKET_ACCESS_KEY="$("$KEYRING" get "$STATE/keyring.env" BUCKET_ACCESS_KEY)"
BUCKET_SECRET_KEY="$("$KEYRING" get "$STATE/keyring.env" BUCKET_SECRET_KEY)"

if [ ! -f "$STATE/minio-root.env" ]; then
  # Alphanumeric so it is safe inside the MC_HOST_ URL below.
  printf 'MINIO_ROOT_USER=substrate-admin\nMINIO_ROOT_PASSWORD=%s\n' \
    "$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40)" > "$STATE/minio-root.env"
  say "wrote the MinIO admin credential to $STATE/minio-root.env"
fi
ROOT_USER="$(grep -E '^MINIO_ROOT_USER=' "$STATE/minio-root.env" | cut -d= -f2-)"
ROOT_PASSWORD="$(grep -E '^MINIO_ROOT_PASSWORD=' "$STATE/minio-root.env" | cut -d= -f2-)"
if [ -z "$ROOT_USER" ] || [ -z "$ROOT_PASSWORD" ]; then die "$STATE/minio-root.env is incomplete"; fi

# CoreDNS: the Corefile as committed, the zone with the nameserver address in.
cp "$HERE/coredns/Corefile" "$STATE/coredns/Corefile"
sed "s/__NS_IP__/$DNS_IP/" "$HERE/coredns/db.$ZONE.tmpl" > "$STATE/coredns/db.$ZONE"
chmod 0644 "$STATE/coredns/Corefile" "$STATE/coredns/db.$ZONE"
chmod 0755 "$STATE/coredns" "$STATE/minio" "$STATE/registry"

# ---------------------------------------------------------------------------
# Containers. ensure_container NAME IMAGE IP -- <docker run args after --network/--ip>
# lives in scripts/lib/ensure-container.sh and needs NET, say, step and die.
# ---------------------------------------------------------------------------
. "$REPO/scripts/lib/ensure-container.sh"

tcp_wait() {
  local host="$1" port="$2" what="$3" i
  for i in $(seq 1 60); do
    if timeout 1 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then return 0; fi
    sleep 1
  done
  die "$what did not open $host:$port within 60s. docker logs $what"
}

step "containers"
ensure_container "$C_MINIO" "$MINIO_IMAGE" "$MINIO_IP" -- \
  --user "$(id -u):$(id -g)" --env-file "$STATE/minio-root.env" \
  -v "$STATE/minio:/data" \
  "$MINIO_IMAGE" server /data --address :9000 --console-address :9001
ensure_container "$C_DNS" "$COREDNS_IMAGE" "$DNS_IP" -- \
  -v "$STATE/coredns:/etc/coredns:ro" \
  "$COREDNS_IMAGE" -conf /etc/coredns/Corefile
# The setec disk registry (D85). The disk builder pushes each signed disk
# here, and the kubelet pulls it as an image volume. Plain HTTP on a private
# address, as in the setec exit test: the disk builder uses HTTP for an RFC
# 1918 address, and recreate-kind.sh gives containerd on the node a hosts.toml
# for it. The disks outlive each cluster in $STATE/registry, as on AWS.
ensure_container "$C_REGISTRY" "$REGISTRY_IMAGE" "$REGISTRY_IP" -- \
  --user "$(id -u):$(id -g)" \
  -v "$STATE/registry:/var/lib/registry" \
  "$REGISTRY_IMAGE"

tcp_wait "$MINIO_IP" 9000 "$C_MINIO"
tcp_wait "$REGISTRY_IP" 5000 "$C_REGISTRY"
for i in $(seq 1 30); do
  if [ -n "$(dig +short +time=1 +tries=1 "@$DNS_IP" NS "$ZONE" 2>/dev/null)" ]; then break; fi
  [ "$i" -lt 30 ] || die "$C_DNS does not answer NS $ZONE at $DNS_IP. docker logs $C_DNS"
  sleep 1
done
say "all three answer"

# ---------------------------------------------------------------------------
# The bucket, configured with the admin credential: created with object lock
# (which needs versioning), versioning on, one lifecycle rule per prefix, and
# the platform credential (the keyring's BUCKET_ACCESS_KEY) with a policy that
# has no s3:Put*Configuration and no s3:Delete* anywhere except one prefix:
# s3:DeleteObject under backups/velero/, which kopia requires (deploy#1734).
# See the policy below for why that is not a hole.
#
# All of it goes through `mc` inside the MinIO container. Users and policies
# are MinIO admin API, which only mc speaks, and this MinIO release wants
# Content-MD5 on a lifecycle PUT, which aws-cli 2.23+ no longer sends. The
# image ships mc, and MC_HOST_ keeps the admin credential off argv.
#
# Lifecycle:
#   backups/    expire at 180 days, non-current versions at 30
#   audit/      expire at 6 years (2190 days). Object lock is on for the bucket,
#               the audit writer sets retention per object
#   tfstate/    current versions never expire, non-current ones at 365 days
#   preflight/  the canaries preflight writes and cannot delete, gone in a day
#   charts/     the Helm repository a recreate publishes from the checkout
#               (deploy#1737). Argo CD reads it with a plain anonymous GET,
#               so the prefix gets a download policy: MinIO speaks S3, Argo
#               speaks basic auth, and anonymous read of versioned charts
#               with no secret in them is the smaller surface. Reachable on
#               the kind Docker network only. Gone in 30 days.
# ---------------------------------------------------------------------------
step "bucket $BUCKET"
mc() {
  docker exec -i -e MC_CONFIG_DIR=/tmp/mc \
    -e "MC_HOST_local=http://$ROOT_USER:$ROOT_PASSWORD@127.0.0.1:9000" \
    "$C_MINIO" mc --quiet "$@"
}
mc mb --ignore-existing --with-lock "local/$BUCKET" >/dev/null
mc version enable "local/$BUCKET" >/dev/null
mc ilm import "local/$BUCKET" >/dev/null <<'JSON'
{
  "Rules": [
    {"ID": "backups",   "Status": "Enabled", "Filter": {"Prefix": "backups/"},
     "Expiration": {"Days": 180}, "NoncurrentVersionExpiration": {"NoncurrentDays": 30}},
    {"ID": "audit",     "Status": "Enabled", "Filter": {"Prefix": "audit/"},
     "Expiration": {"Days": 2190}},
    {"ID": "tfstate",   "Status": "Enabled", "Filter": {"Prefix": "tfstate/"},
     "NoncurrentVersionExpiration": {"NoncurrentDays": 365}},
    {"ID": "preflight", "Status": "Enabled", "Filter": {"Prefix": "preflight/"},
     "Expiration": {"Days": 1}},
    {"ID": "charts",    "Status": "Enabled", "Filter": {"Prefix": "charts/"},
     "Expiration": {"Days": 30}, "NoncurrentVersionExpiration": {"NoncurrentDays": 7}}
  ]
}
JSON
mc anonymous set download "local/$BUCKET/charts" >/dev/null
say "object lock and versioning on, lifecycle rules for backups/ audit/ tfstate/ preflight/ charts/, anonymous download on charts/"

step "platform credential"
cat > "$WORK/policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow",
     "Action": ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketVersions",
                "s3:ListBucketMultipartUploads", "s3:GetBucketVersioning",
                "s3:GetLifecycleConfiguration", "s3:GetBucketObjectLockConfiguration"],
     "Resource": ["arn:aws:s3:::$BUCKET"]},
    {"Effect": "Allow",
     "Action": ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject",
                "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts",
                "s3:GetObjectRetention", "s3:PutObjectRetention"],
     "Resource": ["arn:aws:s3:::$BUCKET/*"]},
    {"Effect": "Allow",
     "Action": ["s3:DeleteObject"],
     "Resource": ["arn:aws:s3:::$BUCKET/backups/velero/*"]}
  ]
}
JSON
docker exec -i -e MC_CONFIG_DIR=/tmp/mc \
  -e "MC_HOST_local=http://$ROOT_USER:$ROOT_PASSWORD@127.0.0.1:9000" \
  "$C_MINIO" sh -c "cat > /tmp/$PLATFORM_POLICY.json && mc --quiet admin policy create local $PLATFORM_POLICY /tmp/$PLATFORM_POLICY.json" \
  < "$WORK/policy.json" >/dev/null
mc admin user add local "$BUCKET_ACCESS_KEY" "$BUCKET_SECRET_KEY" >/dev/null
if ! mc admin user info local "$BUCKET_ACCESS_KEY" --json | grep -q "\"$PLATFORM_POLICY\""; then
  mc admin policy attach local "$PLATFORM_POLICY" --user "$BUCKET_ACCESS_KEY" >/dev/null
fi
say "user $BUCKET_ACCESS_KEY holds policy $PLATFORM_POLICY (s3:DeleteObject under backups/velero/ only)"

# ---------------------------------------------------------------------------
# substrate.env: the one artifact stage 1 may read. No secrets. Atomic write.
# ---------------------------------------------------------------------------
step "substrate.env"
fingerprints="$("$KEYRING" fingerprints "$STATE/keyring.env")"
{
  printf '# substrate.env for ENV=kind, stage 0 of ADR-0083. Written %s by kind/substrate/substrate.sh.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '# No secrets here. preflight reads this file and KEYRING_FILE, nothing else.\n'
  printf 'SUBSTRATE_ENV=kind\n'
  printf 'BUCKET_ENDPOINT=http://%s:9000\n' "$MINIO_IP"
  printf 'BUCKET_REGION=%s\n' "$REGION"
  printf 'BUCKET_NAME=%s\n' "$BUCKET"
  printf 'KEYRING_FILE=%s\n' "$STATE/keyring.env"
  printf '%s\n' "$fingerprints"
  printf 'ZONE_NAME=%s\n' "$ZONE"
  printf 'ZONE_NAMESERVER=%s\n' "$DNS_IP"
  # The repository of the signed setec sandbox disks (D85). recreate-kind.sh
  # and the charts install (scripts/baseline-up.sh) set
  # setec.launcher.diskRepo from it.
  printf 'SETEC_DISK_REPO=%s:5000/%s\n' "$REGISTRY_IP" "$DISK_REPO_NAME"
} > "$WORK/substrate.env"
chmod 0644 "$WORK/substrate.env"
mv "$WORK/substrate.env" "$STATE/substrate.env"
say "wrote $STATE/substrate.env"
printf '    bucket   http://%s:9000/%s   console http://%s:9001\n' "$MINIO_IP" "$BUCKET" "$MINIO_IP"
printf '    zone     %s at %s\n' "$ZONE" "$DNS_IP"
printf '    disks    %s:5000/%s\n' "$REGISTRY_IP" "$DISK_REPO_NAME"
printf '    keyring  %s\n' "$STATE/keyring.env"
printf '    next     make preflight ENV=kind\n'
