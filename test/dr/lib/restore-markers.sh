# shellcheck shell=bash
# ---------------------------------------------------------------------------
# restore-markers.sh — known records in each store that a backup covers, written
# before a backup and read after a restore (hosted#443, ADR-0083).
#
# SOURCED. Two callers run the same code:
#   test/dr/preserve-restore-loop.sh   the blocker 3 loop on kind
#   test/dr/restore-markers.sh         the CLI that the drill workflow runs
#                                      through `make with-cluster`
#
# The stores and their records:
#   the tenant records (Velero)    a Tenant CR, Ready
#   the tenant graph (Velero)      a RestoreLoopMarker node in its Neo4j
#   the platform database (CNPG)   a row in restore_loop_marker
#   the secret store (Velero)      the master transit key of the tenant keys:
#                                  an HMAC of a marker under it
#
# The tenant key of each tenant is HMAC-SHA256(master transit key, tenant id),
# made by the tenant-operator (gibson operators/tenant/internal/clients/vault
# transit.go). The master key lives only in the volume of the store, so the
# same HMAC after a restore proves that every tenant key came back, and a
# different HMAC after a wipe proves that none did.
#
# The caller sets NS, TENANT, TENANT_NS, TIER, PLAINTEXT, GRAPH_MARKER,
# READY_TIMEOUT and KEK_MAC (check only), and defines die() and note().
#
#   markers_seed     write each record and read it back. Sets KEK_MAC.
#   markers_check    each record is present and the same. The master key
#                    gives the HMAC that markers_seed recorded.
#   markers_absent   no record is present (a wipe and a nameless recreate).
# ---------------------------------------------------------------------------

# --- the store -------------------------------------------------------------

bao_pod() {
  kubectl -n "$NS" get pods -l app.kubernetes.io/component=openbao \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# bao <command…> — run one `bao` command inside the store, with the token of
# the tenant-operator read from its Secret. That token may HMAC under the
# master transit key (policy tenant-operator), which is the one thing these
# markers ask of the store. The token goes in on STDIN, so it never
# reaches an argv or the process table. The command keeps the BAO_ADDR and
# BAO_CACERT of the openbao container: the listener serves TLS only
# (charts#540), so a plain http address fails each call (hosted#536).
bao() {
  local pod tok
  pod="$(bao_pod)"
  [ -n "$pod" ] || die "no OpenBao pod in namespace ${NS}"
  tok="$(kubectl -n "$NS" get secret gibson-tenant-operator-vault \
    -o jsonpath='{.data.VAULT_ADMIN_TOKEN}' 2>/dev/null | base64 -d)"
  [ -n "$tok" ] || die "Secret ${NS}/gibson-tenant-operator-vault holds no VAULT_ADMIN_TOKEN: the store never finished its bootstrap"
  printf '%s' "$tok" | kubectl -n "$NS" exec -i "$pod" -c openbao -- \
    sh -c 'read -r T; BAO_TOKEN="$T" '"$*"
}

# A lost answer is not an empty answer. kubectl's WebSocket exec can drop a
# fast command's whole stdout frame ("websocket.go: Unknown stream id 1,
# discarding message"). Run 36342878050 lost the output of `bao list` that
# way, and the step read the silence as "the key is absent". In the wipe
# check the same silence would PASS by accident. So bao_field accepts only a
# non-empty answer, retries a lost one, and fails by name when every attempt
# is lost.

# transit_key — the name of the master transit key, read from the
# tenant-operator, so the name is never a second copy here.
transit_key() {
  local k
  k="$(kubectl -n "$NS" get deploy gibson-tenant-operator \
    -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="GIBSON_VAULT_TRANSIT_KEY")].value}' 2>/dev/null)"
  [ -n "$k" ] || die "the tenant-operator names no GIBSON_VAULT_TRANSIT_KEY, so this run cannot ask the store for the master key"
  printf '%s' "$k"
}

# kek_mac — the HMAC of PLAINTEXT under the master transit key, the way the
# tenant-operator derives each tenant key (sha2-256).
kek_mac() {
  bao_field "bao write -field=hmac transit/hmac/$(transit_key)/sha2-256 input=\$(printf '%s' '${PLAINTEXT}' | base64)"
}

# bao_field <command> — one -field value. Empty output is a lost answer: the
# commands used here always print a value when they succeed.
bao_field() {
  local out i
  for i in 1 2 3 4; do
    out="$(bao "$1" | tr -d '\r')" || true
    if [ -n "$out" ]; then
      printf '%s' "$out"
      return 0
    fi
    echo "bao: empty answer on attempt ${i} for: ${1%% *}…" >&2
    sleep 3
  done
  die "bao returned no output in 4 attempts for a command that always prints one. The answer was lost"
}

# --- the platform database -------------------------------------------------

# psql <statement> — run one statement in the CNPG primary. Postgres is the
# one store that does NOT ride in the Velero backup: it comes back through its
# own barman archive, so a row written here is what proves the recovery target
# the recreate read out of the named backup actually recovered.
psql() {
  local primary
  primary="$(kubectl -n "$NS" get cluster.postgresql.cnpg.io/platform-postgres \
    -o jsonpath='{.status.currentPrimary}' 2>/dev/null)"
  [ -n "$primary" ] || die "the CNPG Cluster platform-postgres reports no primary"
  kubectl -n "$NS" exec "$primary" -c postgres -- \
    psql -U postgres -d postgres -tAqc "$1"
}

# --- the tenant graph ------------------------------------------------------

cypher() {
  # Run one statement in the tenant's own Neo4j, as the tenant operator
  # provisioned it. The credential is the pod's own NEO4J_AUTH, read inside
  # the container: this script never handles it.
  local pod
  pod="$(kubectl -n "$TENANT_NS" get pods -l app.kubernetes.io/component=tenant-neo4j \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [ -n "$pod" ] || die "no tenant Neo4j pod in namespace ${TENANT_NS} (label app.kubernetes.io/component=tenant-neo4j)"
  kubectl -n "$TENANT_NS" exec "$pod" -c neo4j -- sh -c \
    'A="${NEO4J_AUTH:-$(cat "$NEO4J_AUTH_PATH")}"; exec cypher-shell --format plain -a bolt://127.0.0.1:7687 -u "${A%%/*}" -p "${A#*/}" "'"$1"'"'
}

wait_for() {
  # wait_for <seconds> <what> -- <command…>
  local deadline=$(( $(date +%s) + $1 )) what="$2"; shift 3
  while :; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    [ "$(date +%s)" -lt "$deadline" ] || die "$what"
    sleep 10
  done
}

markers_seed() {
  kubectl apply -f - <<YAML
apiVersion: gibson.zeroroot.ai/v1alpha1
kind: Tenant
metadata:
  name: ${TENANT}
spec:
  displayName: Restore Loop
  owner: restore-loop@zeroroot.ai
  tier: ${TIER}
YAML
  kubectl wait --for=jsonpath='{.status.phase}'=Ready "tenant/${TENANT}" --timeout="${READY_TIMEOUT}s" \
    || die "tenant ${TENANT} never reached Ready, so there is no tenant to lose"
  note "tenant ${TENANT} is Ready, data plane in ${TENANT_NS}"

  wait_for "$READY_TIMEOUT" "the tenant Neo4j pod never became Ready in ${TENANT_NS}" -- \
    kubectl -n "$TENANT_NS" wait --for=condition=Ready pod \
      -l app.kubernetes.io/component=tenant-neo4j --timeout=60s
  cypher "CREATE (n:RestoreLoopMarker {id: '${GRAPH_MARKER}'})" >/dev/null \
    || die "could not write the marker node into the tenant graph"
  READ_BACK="$(cypher "MATCH (n:RestoreLoopMarker) RETURN n.id" | tail -n1 | tr -d '"\r')"
  [ "$READ_BACK" = "$GRAPH_MARKER" ] \
    || die "the tenant graph does not hold the marker it was just given (read back: ${READ_BACK})"
  note "graph node written and read back"

  # The platform database. This row has to exist BEFORE the preserve teardown
  # takes its CNPG base backup, which is step 3's first action.
  psql "CREATE TABLE IF NOT EXISTS restore_loop_marker (id text primary key)" >/dev/null \
    || die "could not create the marker table in the platform database"
  psql "INSERT INTO restore_loop_marker VALUES ('${GRAPH_MARKER}') ON CONFLICT DO NOTHING" >/dev/null \
    || die "could not write the marker row"
  PG_READ="$(psql "SELECT id FROM restore_loop_marker" | tr -d '\r')"
  [ "$PG_READ" = "$GRAPH_MARKER" ] \
    || die "the platform database does not hold the row it was just given (read back: '${PG_READ}')"
  note "postgres row written and read back"

  # The tenant keys. The master transit key lives ONLY in the secret store's
  # own volume, so an HMAC under it is the sharpest probe of whether that
  # volume came back.
  KEK_MAC="$(kek_mac)"
  case "$KEK_MAC" in vault:v*:*) ;; *) die "the store gave no HMAC under the master transit key (got '${KEK_MAC%%:*}')" ;; esac
  note "the HMAC of the marker under the master transit key is recorded (${KEK_MAC%:*})"

}

markers_check() {
  kubectl get "tenant/${TENANT}" >/dev/null 2>&1 \
    || die "tenant ${TENANT} is not in the restored cluster: the restore did not bring the tenant records back"
  kubectl wait --for=jsonpath='{.status.phase}'=Ready "tenant/${TENANT}" --timeout="${READY_TIMEOUT}s" \
    || die "the restored tenant ${TENANT} never reached Ready"
  note "tenant ${TENANT} is back and Ready"
  # The restore creates the tenant namespace without the operator's label,
  # before Velero restores into it, so the admission policy
  # gibson-tenant-namespace-label admits it (hosted row 11, #788). The
  # operator sets the label when it reconciles the restored Tenant. A
  # namespace without it has no reconciled Tenant.
  LABEL="$(kubectl get namespace "$TENANT_NS" -o jsonpath='{.metadata.labels.gibson\.zeroroot\.ai/managed-by}' 2>/dev/null)"
  [ "$LABEL" = tenant-operator ] \
    || die "the restored tenant namespace ${TENANT_NS} carries gibson.zeroroot.ai/managed-by='${LABEL}', not tenant-operator: the operator did not reconcile the restored Tenant"
  printf '\033[1;32m     ✓ the tenant namespace %s carries the operator label again\033[0m\n' "$TENANT_NS"

  RESTORED_MAC="$(kek_mac)"
  [ "$RESTORED_MAC" = "$KEK_MAC" ] \
    || die "the restored store gives a DIFFERENT HMAC under the master transit key than before the teardown.
      A key of the same name exists and it is a DIFFERENT key, so every tenant key derived from it
      is different and no tenant secret decrypts. A key-name check would have called this a pass"
  printf '\033[1;32m     ✓ the master transit key gives the pre-teardown HMAC: every tenant key came back\033[0m\n'

  wait_for "$READY_TIMEOUT" "the restored tenant Neo4j pod never became Ready in ${TENANT_NS}" -- \
    kubectl -n "$TENANT_NS" wait --for=condition=Ready pod \
      -l app.kubernetes.io/component=tenant-neo4j --timeout=60s
  RESTORED_GRAPH="$(cypher "MATCH (n:RestoreLoopMarker) RETURN n.id" | tail -n1 | tr -d '"\r')"
  [ "$RESTORED_GRAPH" = "$GRAPH_MARKER" ] \
    || die "the restored tenant graph does not hold the node written before the teardown (read back: '${RESTORED_GRAPH}')"
  printf '\033[1;32m     ✓ the tenant graph node reads back: %s\033[0m\n' "$RESTORED_GRAPH"

  # Postgres came back a different way from everything else: the recreate read
  # the CNPG base backup id out of the NAMED Velero backup and rendered
  # bootstrap.recovery with it. If that id were wrong, or the field name were
  # one CNPG does not have, the Cluster would silently run initdb instead and
  # every assertion above would still pass.
  RESTORED_PG="$(psql "SELECT id FROM restore_loop_marker" 2>/dev/null | tr -d '\r')"
  [ "$RESTORED_PG" = "$GRAPH_MARKER" ] \
    || die "the platform database does not hold the row written before the teardown (read back: '${RESTORED_PG}').
      Postgres recovers through its own barman archive, not through Velero, so this is the
      bootstrap.recovery half of the restore: an empty answer means the Cluster ran initdb."
  printf '\033[1;32m     ✓ the platform database row reads back: %s\033[0m\n' "$RESTORED_PG"

}

markers_absent() {
  if kubectl get "tenant/${TENANT}" >/dev/null 2>&1; then
    kubectl get tenants.gibson.zeroroot.ai
    die "tenant ${TENANT} is present after a WIPE teardown and a nameless recreate.
      The recreate read the bucket on its own. A wipe teardown is then indistinguishable from a
      preserve teardown, and the two modes mean nothing (ADR-0083)"
  fi
  printf '\033[1;32m     ✓ tenant %s is absent\033[0m\n' "$TENANT"

  if kubectl get namespace "$TENANT_NS" >/dev/null 2>&1; then
    die "namespace ${TENANT_NS} is present after a wipe and a nameless recreate"
  fi
  printf '\033[1;32m     ✓ namespace %s is absent\033[0m\n' "$TENANT_NS"

  if [ "$(kek_mac)" = "$KEK_MAC" ]; then
    die "the master transit key gives the pre-teardown HMAC after a wipe and a nameless recreate: the secret store was restored without being asked"
  fi
  printf '\033[1;32m     ✓ the master transit key is a new one: no tenant key came back\033[0m\n'

  if psql "SELECT 1 FROM restore_loop_marker LIMIT 1" >/dev/null 2>&1; then
    die "the platform database still holds the marker table after a wipe and a nameless recreate: Postgres recovered from the archive without being asked"
  fi
  printf '\033[1;32m     ✓ the platform database is empty of the marker table\033[0m\n'

}
