#!/usr/bin/env bash
# harness.sh — the edge harness (ADR-0079, deploy#1657). Runs the chart's own
# Envoy edge, the chart's own ratelimit service and a Redis under Docker, with
# no cluster, so the edge exit tests (rate limit, WAF) prove the RENDERED
# config offline.
#
#   harness.sh up    render, transform (test/edge/transform.py), start
#   harness.sh down  stop and remove everything
#
# Containers on one user-defined network with a fixed subnet, so client
# containers can take DISTINCT source addresses — the peer Envoy sees is real
# (Client-IP contract), never a header:
#
#   gibson-workloads-dashboard  a stub upstream (Envoy direct_response 200),
#                               named as the render's gibson_dashboard cluster
#                               endpoint so the bootstrap needs no edit
#   <release>-redis-stack       Redis, requirepass, named as REDIS_URL's host
#   gibson-ratelimit            envoyproxy/ratelimit from the values' image,
#                               the Deployment's env, the ConfigMap's config
#   edge-envoy                  the rendered bootstrap, the pinned Envoy image,
#                               the Coraza module copied out of the render's
#                               WAF image (what copy-coraza-wasm does in-pod)
#
# Env:
#   CHARTS_ROOT checkout of zeroroot-ai/charts (default: the sibling ../charts,
#              the same default the Makefile exports). This repo holds no
#              charts (ADR-0086), so the render must come from there.
#   VALUES     values file for the umbrella render (default values-baseline.yaml, the kind profile)
#   WORK       working directory (default: mktemp)
#   NET/SUBNET Docker network name / subnet (default edge-harness / 203.0.113.0/24)
#   ENVOY_IMAGE, REDIS_IMAGE, CURL_IMAGE  mirrored images (defaults below)
# Writes WORK/env.sh for the assertion scripts to source.
set -euo pipefail

cd "$(dirname "$0")/../.."

# The umbrella with the baseline profile is what kind runs (recreate-kind.sh
# stage 2), so that is what the edge is proven against. gibson-workloads on
# its own cannot render: its required values come from the umbrella.
CHARTS_ROOT="${CHARTS_ROOT:-$(pwd)/../charts}"
CHART="$CHARTS_ROOT/helm/gibson"
VALUES="${VALUES:-$CHART/values-baseline.yaml}"
NET="${NET:-edge-harness}"
SUBNET="${SUBNET:-203.0.113.0/24}"
ENVOY_IMAGE="${ENVOY_IMAGE:-ghcr.io/zeroroot-ai/mirror/envoy:v1.34.0}"
REDIS_IMAGE="${REDIS_IMAGE:-ghcr.io/zeroroot-ai/mirror/redis:7.4-alpine}"
CURL_IMAGE="${CURL_IMAGE:-ghcr.io/zeroroot-ai/mirror/curl:8.10.1}"
export HARNESS_REDIS_PASSWORD="${HARNESS_REDIS_PASSWORD:-harness-$RANDOM}"

json() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$WORK/harness.json" "$1"; }

down() {
  for c in edge-envoy gibson-ratelimit gibson-workloads-dashboard; do docker rm -f "$c" >/dev/null 2>&1 || true; done
  docker ps -aq --filter "network=$NET" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}

up() {
  # Only up renders; down must work with no chart checkout (the CI teardown
  # step runs without CHARTS_ROOT).
  [ -d "$CHART" ] || { echo "edge harness: no chart at $CHART. Clone zeroroot-ai/charts next to this repo (and run make chart-deps there), or set CHARTS_ROOT=<checkout>" >&2; exit 2; }
  # A caller-supplied WORK (the CI action passes one under the runner temp)
  # does not exist yet; mktemp -d creates its own.
  WORK="${WORK:-$(mktemp -d)}"; export WORK; mkdir -p "$WORK"
  echo "→ work dir $WORK"
  # The one operator value the baseline profile does not carry. charts#113
  # made platformPostgres.backup.destinationPath REQUIRED with no default (a
  # profile must never ship an archive bucket) and moved the kind value into
  # the rungs; `make recreate ENV=kind` supplies it from substrate.env. This
  # harness renders the baseline the way the verb does, so it supplies one
  # too. Nothing here archives: the render is read for the Envoy config only.
  # The setec chart also fails the render without a disk registry and a disk
  # public key (D85). Nothing here pulls or verifies a disk, so both are
  # placeholders. The audit export names the same bucket as the archive
  # (charts#446), and the harness never writes to it.
  helm template gibson "$CHART" -f "$VALUES" --namespace gibson \
    --set platformPostgres.backup.destinationPath=s3://edge-harness/backups/postgres/ \
    --set gibson-workloads.setec.launcher.diskRepo=edge-harness.invalid/setec-disks \
    --set 'gibson-workloads.setec.launcher.diskBuilder.publicKeys[0]=fXleDoHDAcpJhUjK9Hl64f2bMSOdJBeHHbuP6td75vs=' \
    --set gibson-workloads.gibson.auditExport.bucket=edge-harness \
    --set gibson-workloads.gibson.auditExport.lockMode=GOVERNANCE \
    > "$WORK/all.yaml"
  python3 test/edge/transform.py "$WORK/all.yaml" "$WORK"

  # The edge terminates TLS with a cert-manager Secret in the cluster; here, a
  # throwaway pair. Chain selection is by SNI, so the name must be the app host.
  mkdir -p "$WORK/tls"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$(json app_host)" \
    -keyout "$WORK/tls/tls.key" -out "$WORK/tls/tls.crt" >/dev/null 2>&1
  chmod 644 "$WORK/tls/tls.key" "$WORK/tls/tls.crt" "$WORK/envoy.yaml"
  chmod -R a+rX "$WORK/ratelimit"

  # The Edge WAF module: copy /plugin.wasm out of the render's
  # copy-coraza-wasm image, exactly what the init container does in the pod.
  # WAF_IMAGE overrides it for a LOCAL run before the mirror carries the tag.
  mkdir -p "$WORK/wasm"
  local waf_img; waf_img="${WAF_IMAGE:-$(json waf_image)}"
  docker rm -f edge-harness-wasm >/dev/null 2>&1 || true
  docker create --name edge-harness-wasm "$waf_img" >/dev/null
  docker cp edge-harness-wasm:/plugin.wasm "$WORK/wasm/coraza.wasm"
  docker rm -f edge-harness-wasm >/dev/null
  chmod 644 "$WORK/wasm/coraza.wasm"
  echo "→ WAF module $(wc -c < "$WORK/wasm/coraza.wasm") bytes from $waf_img"

  down
  docker network create --subnet "$SUBNET" "$NET" >/dev/null

  local redis_host; redis_host="$(json redis_host)"
  docker run -d --name "$redis_host" --network "$NET" "$REDIS_IMAGE" \
    redis-server --requirepass "$HARNESS_REDIS_PASSWORD" >/dev/null

  # RATELIMIT_IMAGE overrides the values' image for a LOCAL run before the
  # mirror carries a new tag. CI never sets it: the render's image is the test.
  # REDIS_AUTH comes from this environment, not from the env file, so the
  # password is never written to disk or put on a command line.
  REDIS_AUTH="$HARNESS_REDIS_PASSWORD" docker run -d --name gibson-ratelimit --network "$NET" \
    --env-file "$WORK/ratelimit.env" -e REDIS_AUTH \
    -v "$WORK/ratelimit/config:/data/ratelimit/config:ro" \
    "${RATELIMIT_IMAGE:-$(json ratelimit_image)}" >/dev/null

  # Stub upstream: ONE container answering 200 on every (host, port) the
  # render's plain-HTTP upstream clusters name (dashboard, native login,
  # Zitadel), aliased on the network under each hostname so the rendered
  # bootstrap needs no edit.
  local stub_cfg aliases
  stub_cfg="$(python3 - "$WORK/harness.json" <<'PY'
import json, sys
info = json.load(open(sys.argv[1]))
ports = sorted({p for _, p in info["stub_endpoints"]})
hcm = """      filter_chains:
        - filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                '@type': type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                stat_prefix: stub%d
                route_config:
                  virtual_hosts:
                    - name: stub
                      domains: ['*']
                      routes:
                        - match: { prefix: / }
                          direct_response: { status: 200, body: { inline_string: 'stub ok' } }
                http_filters:
                  - name: envoy.filters.http.router
                    typed_config: { '@type': type.googleapis.com/envoy.extensions.filters.http.router.v3.Router }"""
print("static_resources:\n  listeners:")
for p in ports:
    print("    - address: { socket_address: { address: 0.0.0.0, port_value: %d } }" % p)
    print(hcm % p)
PY
)"
  aliases="$(python3 -c "import json,sys; print(' '.join('--network-alias '+h for h in sorted({h for h,_ in json.load(open(sys.argv[1]))['stub_endpoints']})))" "$WORK/harness.json")"
  # shellcheck disable=SC2086
  docker run -d --name "$(json dashboard_host)" --network "$NET" $aliases "$ENVOY_IMAGE" \
    --service-node stub --service-cluster stub --config-yaml "$stub_cfg" >/dev/null

  docker run -d --name edge-envoy --network "$NET" \
    -v "$WORK/envoy.yaml:/etc/envoy/envoy.yaml:ro" \
    -v "$WORK/tls:/etc/envoy/tls:ro" \
    -v "$WORK/wasm:/etc/envoy/wasm:ro" \
    "$ENVOY_IMAGE" -c /etc/envoy/envoy.yaml --service-node ci --service-cluster ci \
    --log-level warn >/dev/null

  local edge_ip; edge_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' edge-envoy)"
  local admin; admin="$edge_ip:$(json admin_port)"
  echo "→ waiting for edge-envoy /ready at $admin (SDS to a missing SPIRE socket times out first, ~15s)"
  local i
  for i in $(seq 1 60); do
    if docker run --rm --network "$NET" "$CURL_IMAGE" -fs "http://$admin/ready" >/dev/null 2>&1; then
      echo "→ edge-envoy ready after ${i}s"; break
    fi
    sleep 1
    [ "$i" -eq 60 ] && { echo "edge-envoy never became ready" >&2; docker logs edge-envoy | tail -40 >&2; exit 1; }
  done
  for i in $(seq 1 30); do
    if docker run --rm --network "$NET" "$CURL_IMAGE" -fs "http://gibson-ratelimit:8080/healthcheck" >/dev/null 2>&1; then
      echo "→ gibson-ratelimit healthy after ${i}s"; break
    fi
    sleep 1
    [ "$i" -eq 30 ] && { echo "gibson-ratelimit never became healthy" >&2; docker logs gibson-ratelimit | tail -40 >&2; exit 1; }
  done

  cat > "$WORK/env.sh" <<EOF
export NET='$NET'
export CURL_IMAGE='$CURL_IMAGE'
export EDGE_IP='$edge_ip'
export EDGE_PORT='$(json edge_port)'
export ADMIN='$admin'
export APP_HOST='$(json app_host)'
export API_HOST='$(json api_host)'
export WORK='$WORK'
EOF
  echo "→ harness up; source $WORK/env.sh"
}

case "${1:-up}" in
  up) up ;;
  down) down ;;
  *) echo "usage: $0 up|down" >&2; exit 2 ;;
esac
