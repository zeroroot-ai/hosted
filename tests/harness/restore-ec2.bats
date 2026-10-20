#!/usr/bin/env bats
#
# restore-ec2.bats: the restore half of the EC2 and EKS recreate RUNS, in
# the right order, with only the inputs the verb has.
#
# WHY THIS SUITE EXISTS
# ---------------------
# recreate.bats and drill-restore.bats read the scripts. They do not run the
# restore tail, scripts/lib/bringup-after-cluster.sh. Three defects of that
# tail were invisible to them:
#
#   1. apply_overlay_app read GH_PAT. The GitHub App (#41) removed the PAT,
#      and nothing set it, so under set -u the restore stopped at its first
#      Application.
#   2. The tail waited for every Application BEFORE the data restore. Argo
#      then created each store with an empty volume, and Velero
#      (existingResourcePolicy: none) skipped each claim and pod: no data.
#      scripts/recreate-kind.sh has the other order.
#   3. Restore 1 brings back the OpenBao pod, which mounts Secret
#      gibson-openbao-tls. A Certificate of the gibson Application issues
#      it, and that Application does not exist yet. The pod never started, so
#      its volume restore never started.
#   4. The EC2 render of platform-postgres had bootstrap.initdb, so Postgres
#      came back empty. D91: the verb puts three recovery values, derived
#      from the named backup, on the gibson Application before the
#      app-of-apps exists, and Git catches up by a PR.
#   5. The archive gate refused every restore: the archive the restore reads
#      is full by design. It now knows the mode (D91).
#
# HOW IT IS OFFLINE
# -----------------
# A driver sets the variables that recreate-ec2.sh sets, sources
# lib/velero-restore.sh and then the tail, the way bringup-before-cluster.sh
# and recreate-ec2.sh do. kubectl, helm and curl are stubs on PATH. The
# kubectl stub answers only the object names this suite declares. Any other
# name gets NotFound, the answer of a real cluster. keyring-to-cluster.sh and
# the two wait libraries are stubs in a copy of scripts/, because their own
# suites own their behavior. Each stub writes one line to order.log.
#
# Run:
#   bats tests/harness/restore-ec2.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
BACKUP="preserve-drill-20261012-040000"
BACKUP_ID="20261012T040000"
SOURCE_ARCHIVE="platform-postgres-20261012"
RESTORE_ARCHIVE="platform-postgres-20261012-r20261012T040000"
# RFC 8032 test vector 1, so its public key is known.
DISK_SEED="nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A="
DISK_PUBLIC_KEY="11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="

load "$BATS_TEST_DIRNAME/assert.bash"

setup() {
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  STATE="$BATS_TEST_TMPDIR/state"
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$STUB_DIR" "$STATE/applied" "$TREE/gitops/envs"
  PATH="$STUB_DIR:$PATH"
  export STATE BACKUP BACKUP_ID SOURCE_ARCHIVE RESTORE_ARCHIVE
  export STUB_UNLABELED_NS=""   # tenant namespaces the operator has not labeled yet
  cp -R "$REPO_ROOT/scripts" "$TREE/scripts"
  cp -R "$REPO_ROOT/gitops/envs/drill" "$TREE/gitops/envs/drill"
  mkdir -p "$TREE/test" && cp -R "$REPO_ROOT/test/dr" "$TREE/test/dr"
  : > "$STATE/order.log"
  printf 'SUBSTRATE_ENV=drill\nEDGE_CERT_SECRET=zeroroot-ai/drill/edge-tls\n' > "$STATE/substrate.env"
  write_stubs
}

write_stubs() {
  cat > "$TREE/scripts/keyring-to-cluster.sh" <<'SH'
#!/usr/bin/env bash
echo "keyring" >> "$STATE/order.log"
SH
  chmod +x "$TREE/scripts/keyring-to-cluster.sh"
  cat > "$TREE/scripts/lib/wait-apps.sh" <<'SH'
wait_apps() { echo "wait_apps" >> "$STATE/order.log"; }
wait_externalsecrets() { echo "wait_externalsecrets" >> "$STATE/order.log"; }
SH
  cat > "$TREE/scripts/lib/wait-archiving.sh" <<'SH'
wait_archiving() { echo "wait_archiving" >> "$STATE/order.log"; }
SH

  cat > "$STUB_DIR/helm" <<'SH'
#!/usr/bin/env bash
echo "helm $*" >> "$STATE/helm.log"
exit 0
SH
  # The overlay is in the checkout. A call to the GitHub API is the old path.
  cat > "$STUB_DIR/curl" <<'SH'
#!/usr/bin/env bash
echo "curl $*" >> "$STATE/curl.log"
exit 22
SH

  cat > "$STUB_DIR/kubectl" <<'SH'
#!/usr/bin/env bash
args="$*"
echo "kubectl $args" >> "$STATE/kubectl.log"
B="$BACKUP"
case "$args" in
  "apply -f -")
    doc="$(cat)"
    kind="$(printf '%s\n' "$doc" | sed -n 's/^kind: //p' | head -1)"
    name="$(printf '%s\n' "$doc" | sed -n 's/^  name: //p' | head -1)"
    printf '%s\n' "$doc" > "$STATE/applied/${kind}-${name}.yaml"
    echo "apply ${kind} ${name}" >> "$STATE/order.log"
    exit 0 ;;
  "apply -f "*)
    f="${args#apply -f }"
    [ -s "$f" ] || { echo "error: the path \"$f\" does not exist" >&2; exit 1; }
    echo "apply-file $(basename "$f")" >> "$STATE/order.log"
    cp "$f" "$STATE/applied/file-$(basename "$f")"
    exit 0 ;;
  "-n argocd get application/gibson-operator-crds -o jsonpath={.status.sync.status}"|\
  "-n argocd get application/gibson-crds -o jsonpath={.status.sync.status}"|\
  "-n argocd get application/gibson-velero -o jsonpath={.status.sync.status}")
    printf 'Synced'; exit 0 ;;
  "-n argocd get application/gibson-operator-crds -o jsonpath={.status.health.status}"|\
  "-n argocd get application/gibson-crds -o jsonpath={.status.health.status}"|\
  "-n argocd get application/gibson-velero -o jsonpath={.status.health.status}")
    printf 'Healthy'; exit 0 ;;
  "-n velero rollout status deployment/velero --timeout=300s") exit 0 ;;
  "-n velero get backup.velero.io/$B") exit 0 ;;
  "-n velero get restore.velero.io/$B-openbao -o jsonpath={.status.phase}"|\
  "-n velero get restore.velero.io/$B-builtins -o jsonpath={.status.phase}"|\
  "-n velero get restore.velero.io/$B-pods -o jsonpath={.status.phase}"|\
  "-n velero get restore.velero.io/$B-statefulsets -o jsonpath={.status.phase}"|\
  "-n velero get restore.velero.io/$B-tenants -o jsonpath={.status.phase}")
    printf 'Completed'; exit 0 ;;
  # The volumes the backup holds bytes for, and the PodVolumeRestores of the
  # pods Restore. STUB_TENANT_PVR_MISSING: the tenant graph volume has none
  # (its StatefulSet made the pod first, review of hosted#790).
  # The PodVolumeBackups, tab separated: namespace, pod, volume, phase, bytes.
  # STUB_PVB_EMPTY: the list holds nothing (no sync, a wrong label). Also in
  # the list: an empty volume, a trainer Job pod with bytes whose suffix is
  # all digits (nothing restores it), and a Failed PodVolumeBackup of that
  # Job pod (audit of the restore path, hosted#793, review of hosted#798).
  # STUB_PVB_LOST: the PodVolumeBackup of a StatefulSet pod failed, so the
  # backup does not hold a volume that the pods Restore brings back.
  "-n velero get podvolumebackups.velero.io -l velero.io/backup-name=$B -o jsonpath={range .items[*]}{.spec.pod.namespace}{\"\\t\"}{.spec.pod.name}{\"\\t\"}{.spec.volume}{\"\\t\"}{.status.phase}{\"\\t\"}{.status.progress.totalBytes}{\"\\n\"}{end}")
    [ -n "${STUB_PVB_EMPTY:-}" ] && exit 0
    printf 'tenant-acme\ttenant-acme-neo4j-0\tdata\tCompleted\t541016231\n'
    printf 'tenant-acme\ttenant-acme-neo4j-0\ttmp\tCompleted\t0\n'
    printf 'tenant-acme\ttenant-acme-neo4j-0\tscratch\tCompleted\t\n'
    # The volumes of the release namespace (hosted#7): the daemon and the SPIRE
    # server are derived, Redis must come back, and an empty one is skipped.
    # STUB_REDIS_PVB_FAILED: the backup saved no Redis volume.
    # STUB_PVB_UNCLASSIFIED: a volume that no class names.
    printf 'gibson\tgibson-gibson-workloads-0\tdata\tCompleted\t6905\n'
    printf 'gibson\tgibson-server-0\tspire-data\tCompleted\t3305\n'
    printf 'gibson\tgibson-gibson-workloads-0\ttmp\tCompleted\t0\n'
    printf 'gibson\tgibson-redis-stack-0\tdata\t%s\t169356\n' "$([ -n "${STUB_REDIS_PVB_FAILED:-}" ] && echo Failed || echo Completed)"
    [ -z "${STUB_PVB_UNCLASSIFIED:-}" ] || printf 'gibson\tgibson-newthing-0\tdata\tCompleted\t100\n'
    printf 'tenant-acme\tbelief-trainer-29123-24577\twork\tCompleted\t4096\n'
    printf 'tenant-acme\tbelief-trainer-29123-24577\tcache\tFailed\t1000\n'
    [ -z "${STUB_PVB_LOST:-}" ] || printf 'tenant-acme\ttenant-acme-neo4j-1\tdata\tFailed\t1000\n'
    printf 'tenant-backup-canary\tbackup-canary\tdata\tCompleted\t65\n'
    exit 0 ;;
  "-n velero get podvolumerestores.velero.io -l velero.io/restore-name=$B-pods -o jsonpath={range .items[*]}{.spec.pod.namespace}/{.spec.pod.name}/{.spec.volume} {.status.phase}{\"\\n\"}{end}")
    [ -n "${STUB_TENANT_PVR_MISSING:-}" ] || printf 'tenant-acme/tenant-acme-neo4j-0/data Completed\n'
    printf 'tenant-backup-canary/backup-canary/data Completed\n'; exit 0 ;;
  # The PodVolumeRestores of every Restore of the run, for the volumes of the
  # release namespace that must come back. STUB_REDIS_PVR_MISSING: Redis has none.
  "-n velero get podvolumerestores.velero.io -l velero.io/restore-name in ("*)
    [ -n "${STUB_REDIS_PVR_MISSING:-}" ] || printf 'gibson/gibson-redis-stack-0/data Completed\n'
    printf 'gibson/gibson-openbao-0/data Completed\n'; exit 0 ;;
  "-n velero get podvolumerestores.velero.io -l velero.io/restore-name=$B-openbao -o jsonpath="*|\
  "-n velero get podvolumerestores.velero.io -l velero.io/restore-name=$B-pods -o jsonpath="*)
    printf 'Completed\n'; exit 0 ;;
  "get clustersecretstore gibson-secrets -o jsonpath="*)
    echo "wait_eso" >> "$STATE/order.log"; printf 'True'; exit 0 ;;
  "get externalsecrets --all-namespaces -o jsonpath="*) printf 'gibson platform-postgres-bucket True\n'; exit 0 ;;
  "get priorityclass gibson-platform -o name"|"get priorityclass gibson-platform-critical -o name"|\
  "get priorityclass tenant-neo4j -o name") exit 0 ;;
  "-n gibson get deploy gibson-tenant-operator -o jsonpath="*) printf '1/1/1'; exit 0 ;;
  "-n gibson get endpoints gibson-tenant-operator-webhook -o jsonpath="*) printf '10.42.0.9'; exit 0 ;;
  "get tenants.gibson.zeroroot.ai -o jsonpath="*) printf 'acme '; exit 0 ;;
  # The tenant namespaces of the backup (hosted row 11, drill run
  # 39180602162): read by the velero binary of the server pod.
  "-n velero get pods -l name=velero --field-selector=status.phase=Running -o jsonpath={.items[0].metadata.name}") printf 'velero-7d9-abc'; exit 0 ;;
  # The backup holds a Tenant acme with its namespace, the backup canary
  # (no Tenant) and the plugin namespace of acme. STUB_LIST_ERROR: velero
  # cannot read the list, and prints one error line under the header.
  "-n velero exec pod/velero-7d9-abc -c velero -- /velero backup describe $B --details -n velero")
    if [ -n "${STUB_LIST_ERROR:-}" ]; then
      printf 'Name:         %s\nPhase:  Completed\n\nResource List:\t<error getting backup resource list: no such key>\n' "$B"; exit 0
    fi
    printf 'Name:         %s\nPhase:  Completed\n\nResource List:\n  apps/v1/StatefulSet:\n    - tenant-acme/tenant-acme-neo4j\n  gibson.zeroroot.ai/v1alpha1/Tenant:\n    - acme\n    - gone\n  v1/Namespace:\n    - gibson\n    - tenant-acme\n    - tenant-acme-plugins\n    - tenant-backup-canary\n    - velero\n  v1/Pod:\n    - tenant-acme/tenant-acme-neo4j-0\n' "$B"
    exit 0 ;;
  "get namespace tenant-acme")
    [ -e "$STATE/applied/Namespace-tenant-acme.yaml" ] || [ -n "${STUB_NS_EXISTS:-}" ] || { echo 'Error from server (NotFound): namespaces "tenant-acme" not found' >&2; exit 1; }
    exit 0 ;;
  "get namespace tenant-acme -o jsonpath={.metadata.labels.gibson\.zeroroot\.ai/managed-by}")
    case " ${STUB_UNLABELED_NS:-} " in *" tenant-acme "*) exit 0 ;; esac
    printf 'tenant-operator'; exit 0 ;;
esac
echo "Error from server (NotFound): kubectl stub: no object for: $args" >&2
exit 1
SH
  # aws: the env's edge certificate secret holds no value yet (the first
  # teardown has not run), the answer of AWS for that case.
  cat > "$STUB_DIR/aws" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "secretsmanager get-secret-value --secret-id zeroroot-ai/drill/edge-tls --query SecretString --output text")
    echo "edge-cert" >> "$STATE/order.log"
    echo "An error occurred (ResourceNotFoundException) when calling the GetSecretValue operation: Secrets Manager can't find the specified secret value for staging label: AWSCURRENT" >&2
    exit 254 ;;
esac
echo "aws stub: undeclared call: $*" >&2; exit 1
SH
  chmod +x "$STUB_DIR/helm" "$STUB_DIR/curl" "$STUB_DIR/kubectl" "$STUB_DIR/aws"

  # The driver: the variables recreate-ec2.sh sets before the tail, and no
  # GH_PAT, because nothing sets one.
  cat > "$BATS_TEST_TMPDIR/drive.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
unset GH_PAT
HERE="$TREE/scripts"; REPO="$TREE"; WORK="$STATE/work"; mkdir -p "$WORK"
SUBSTRATE_ENV="$STATE/substrate.env"; ENV_NAME="${DRIVE_ENV:-drill}"; NS=gibson; VELERO_NS=velero
RESTORE_FROM="${1:-}"; RESTORE_TIMEOUT="${RESTORE_TIMEOUT:-30}"; GITOPS_PATH="gitops/envs/${ENV_NAME}"
# The archive resolve_named_backup leaves in WORK: the pod objects and their
# labels (review of hosted#798).
pods="$WORK/archive/resources/pods/namespaces"
mkdir -p "$pods/tenant-acme" "$pods/tenant-backup-canary"
printf '{"metadata":{"labels":{"statefulset.kubernetes.io/pod-name":"tenant-acme-neo4j-0"}}}' > "$pods/tenant-acme/tenant-acme-neo4j-0.json"
printf '{"metadata":{"labels":{"statefulset.kubernetes.io/pod-name":"tenant-acme-neo4j-1"}}}' > "$pods/tenant-acme/tenant-acme-neo4j-1.json"
printf '{"metadata":{"labels":{"batch.kubernetes.io/job-name":"belief-trainer-29123"}}}' > "$pods/tenant-acme/belief-trainer-29123-24577.json"
printf '{"metadata":{"labels":{"gibson.zeroroot.ai/backup-canary":"true"}}}' > "$pods/tenant-backup-canary/backup-canary.json"
rm -f "$WORK/backup.tar.gz"; [ -n "${STUB_NO_ARCHIVE:-}" ] || tar -czf "$WORK/backup.tar.gz" -C "$WORK/archive" .
TOOLHIVE_VERSION=0.12.1; KUBECONFIG_PATH="$STATE/kubeconfig"
log() { printf 'LOG %s\n' "$*"; }
die() { printf 'DIE %s\n' "$*" >&2; exit 1; }
stage1_enable_app_of_apps() { echo "app-of-apps" >> "$STATE/order.log"; }
. "$HERE/lib/velero-restore.sh"
# What lib/bringup-before-cluster.sh leaves for the tail in restore mode.
RECOVERY_BACKUP_ID="$BACKUP_ID"; RECOVERY_ARCHIVE_NAME="$SOURCE_ARCHIVE"
RESTORE_ARCHIVE_NAME="$RESTORE_ARCHIVE"
. "$HERE/lib/bringup-after-cluster.sh"
SH
  chmod +x "$BATS_TEST_TMPDIR/drive.sh"
  export TREE
}

# line_of <text> — the line number of the first line of order.log that is
# exactly <text>, or 0.
line_of() { grep -n -x -F -- "$1" "$STATE/order.log" | head -1 | cut -d: -f1 || true; }

@test "FAILING FIXTURE (row 4): a restore with no GH_PAT applies the three Applications from the checkout" {
  run "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -eq 0 ] || { echo "$output" >&2; cat "$STATE/order.log" >&2; return 1; }
  refute_output_has "unbound variable"
  for app in gibson-operator-crds gibson-crds gibson-velero; do
    grep -q -x "apply-file ${app}.yaml" "$STATE/order.log"
  done
  [ ! -f "$STATE/curl.log" ] || ! grep -q api.github.com "$STATE/curl.log"
  assert_output_has "restored from backup $BACKUP"
}

@test "FAILING FIXTURE (row 4): an overlay file that is not in the checkout stops the restore and names it" {
  rm "$TREE/gitops/envs/drill/gibson-velero.yaml"
  run "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -ne 0 ]
  assert_output_has "gitops/envs/drill/gibson-velero.yaml"
  [ "$(line_of "apply Restore $BACKUP-openbao")" = "" ]
}

@test "FAILING FIXTURE (R-A): the data restore runs after External Secrets and BEFORE the wait for every Application" {
  run "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -eq 0 ] || { echo "$output" >&2; cat "$STATE/order.log" >&2; return 1; }
  local bao aoa eso builtins tenants apps
  bao="$(line_of "apply Restore $BACKUP-openbao")"
  aoa="$(line_of "app-of-apps")"
  eso="$(line_of "wait_eso")"
  builtins="$(line_of "apply Restore $BACKUP-builtins")"
  tenants="$(line_of "apply Restore $BACKUP-tenants")"
  apps="$(line_of "wait_apps")"
  for n in "$bao" "$aoa" "$eso" "$builtins" "$tenants" "$apps"; do [ -n "$n" ] || { cat "$STATE/order.log" >&2; return 1; }; done
  [ "$bao" -lt "$aoa" ] && [ "$aoa" -lt "$eso" ] && [ "$eso" -lt "$builtins" ] \
    && [ "$builtins" -lt "$tenants" ] && [ "$tenants" -lt "$apps" ] \
    || { cat "$STATE/order.log" >&2; return 1; }
}

@test "FAILING FIXTURE (row 6): restore 1 makes the TLS volumes of the restored OpenBao pod optional, and nothing else" {
  run "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  cm="$(line_of "apply ConfigMap restore-openbao-tls-optional")"
  bao="$(line_of "apply Restore $BACKUP-openbao")"
  [ -n "$cm" ] && [ -n "$bao" ] && [ "$cm" -lt "$bao" ]
  run python3 - "$STATE/applied/Restore-$BACKUP-openbao.yaml" "$STATE/applied/ConfigMap-restore-openbao-tls-optional.yaml" \
    "$STATE/applied/Restore-$BACKUP-builtins.yaml" <<'PY'
import json, sys, yaml
r = yaml.safe_load(open(sys.argv[1]))
assert r["spec"]["resourceModifier"] == {"kind": "ConfigMap", "name": "restore-openbao-tls-optional"}, r["spec"]
cm = yaml.safe_load(open(sys.argv[2]))
assert cm["metadata"]["namespace"] == "velero"
assert len(cm["data"]) == 1, "Velero reads a modifier ConfigMap with exactly one key"
m = yaml.safe_load(next(iter(cm["data"].values())))
rules = m["resourceModifierRules"]
assert len(rules) == 1
c = rules[0]["conditions"]
assert c == {"groupResource": "pods", "namespaces": ["gibson"], "resourceNameRegex": "^gibson-openbao-[0-9]+$"}, c
patch = json.loads(rules[0]["strategicPatches"][0]["patchData"])
vols = patch["spec"]["volumes"]
assert [v["name"] for v in vols] == ["tls", "openbao-ca"], vols
assert all(v["secret"] == {"secretName": "gibson-openbao-tls", "optional": True} for v in vols), vols
assert set(patch) == {"spec"} and set(patch["spec"]) == {"volumes"}, patch
b = yaml.safe_load(open(sys.argv[3]))
assert (b["spec"].get("resourceModifier") or {}).get("name") != "restore-openbao-tls-optional", \
    "the data restore must not patch the OpenBao pod"
PY
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "a fresh recreate creates no Restore and no modifier, and waits for every Application" {
  run "$BATS_TEST_TMPDIR/drive.sh" ""
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  ! grep -q '^apply Restore' "$STATE/order.log" || { echo "a fresh recreate applied a Restore"; false; }
  ! grep -q '^apply ConfigMap' "$STATE/order.log" || { echo "a fresh recreate applied a ConfigMap"; false; }
  ! grep -q '^apply-file' "$STATE/order.log" || { echo "a fresh recreate applied a file"; false; }
  [ -n "$(line_of wait_apps)" ]
  assert_output_has "every store bootstrapped EMPTY"
}

# ---------------------------------------------------------------------------
# Row 11: a restored tenant namespace passes the admission policy
# gibson-tenant-namespace-label, and the operator labels it afterwards.
# ---------------------------------------------------------------------------
@test "FAILING FIXTURE (row 11): the namespace of each Tenant of the backup is created before restore 2, without the policed label (drill run 39180602162)" {
  # Velero creates the namespace of a restored item from the tarball, and a
  # resource modifier does not apply there. The admission policy then
  # refused each tenant namespace. So the restore creates it first.
  run "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  c="$(line_of "apply Namespace tenant-acme")"
  b="$(line_of "apply Restore $BACKUP-builtins")"
  [ -n "$c" ] && [ -n "$b" ] && [ "$c" -lt "$b" ]
  # Only tenant-<name> of a Tenant: not the canary, not the plugin namespace,
  # not gibson or velero.
  # The Tenant gone has no namespace in the backup, so none is created.
  run grep -c "^apply Namespace" "$STATE/order.log"
  [ "$output" = 1 ]
  run python3 - "$STATE/applied/Namespace-tenant-acme.yaml" "$STATE/applied/Restore-$BACKUP-builtins.yaml" "$STATE/applied/Restore-$BACKUP-tenants.yaml" <<'PY'
import sys, yaml
ns = yaml.safe_load(open(sys.argv[1]))
assert ns["metadata"]["labels"] == {"gibson.zeroroot.ai/tenant": "acme",
                                    "pod-security.kubernetes.io/enforce": "restricted"}, ns["metadata"]
for p in sys.argv[2:]:
    r = yaml.safe_load(open(p))
    assert "resourceModifier" not in r["spec"], (p, r["spec"])
PY
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  run grep -c "^apply ConfigMap restore-tenant-namespace-label" "$STATE/order.log"
  [ "$output" = 0 ]
  # The label wait reads tenant-acme only.
  run grep -c "get namespace tenant-backup-canary\|get namespace tenant-acme-plugins" "$STATE/kubectl.log"
  [ "$output" = 0 ]
}

@test "FAILING FIXTURE (row 11): a resource list that velero cannot read stops the restore before restore 2" {
  export STUB_LIST_ERROR=1
  run "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -ne 0 ]
  assert_output_has "does not list the namespace gibson"
  [ -z "$(line_of "apply Restore $BACKUP-builtins")" ]
}

@test "FAILING FIXTURE: only the pods that carry data are restored, after the claims, and the claims restore holds no pod (drill run 39189378263)" {
  # Velero created each Deployment pod as velero-server, and the identity
  # admission policies refused ten of them, so restore 2 ended
  # PartiallyFailed. A Deployment pod holds no data, and its ReplicaSet
  # makes a new one.
  run "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  b="$(line_of "apply Restore $BACKUP-builtins")"
  p="$(line_of "apply Restore $BACKUP-pods")"
  t="$(line_of "apply Restore $BACKUP-tenants")"
  [ -n "$b" ] && [ -n "$p" ] && [ -n "$t" ] && [ "$b" -lt "$p" ] && [ "$p" -lt "$t" ]
  run python3 - "$STATE/applied/Restore-$BACKUP-builtins.yaml" "$STATE/applied/Restore-$BACKUP-pods.yaml" <<'PY'
import sys, yaml
b = yaml.safe_load(open(sys.argv[1]))["spec"]
assert "pods" not in b["includedResources"], b
p = yaml.safe_load(open(sys.argv[2]))["spec"]
assert p["includedResources"] == ["pods", "persistentvolumeclaims", "persistentvolumes"], p
assert "labelSelector" not in p, p
keys = [s["matchExpressions"][0]["key"] for s in p["orLabelSelectors"]]
assert keys == ["statefulset.kubernetes.io/pod-name", "gibson.zeroroot.ai/backup-canary"], keys
# The release namespace is Argo's (audit of the restore path, 2026-10-19).
# The plugin namespace of the backup is the tenant-operator's (hosted#8).
assert p["excludedNamespaces"] == ["gibson", "tenant-acme-plugins"], p
assert all(s["matchExpressions"][0]["operator"] == "Exists" and len(s["matchExpressions"]) == 1 for s in p["orLabelSelectors"]), p
PY
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  # The volume count reads the PodVolumeRestores of the pods restore.
  grep -q "velero.io/restore-name=$BACKUP-pods" "$STATE/kubectl.log"
}

@test "FAILING FIXTURE: the StatefulSets are restored after their pods, and no earlier Restore holds them (review of hosted#790)" {
  # A StatefulSet restored first makes its pod on an empty volume, and the
  # pods Restore then moves no data.
  run "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  p="$(line_of "apply Restore $BACKUP-pods")"
  st="$(line_of "apply Restore $BACKUP-statefulsets")"
  t="$(line_of "apply Restore $BACKUP-tenants")"
  [ -n "$p" ] && [ -n "$st" ] && [ -n "$t" ] && [ "$p" -lt "$st" ] && [ "$st" -lt "$t" ]
  run python3 - "$STATE/applied" "$BACKUP" <<'PY'
import os, sys, yaml
d, b = sys.argv[1], sys.argv[2]
for name in ("openbao", "builtins", "pods", "tenants"):
    r = yaml.safe_load(open(os.path.join(d, f"Restore-{b}-{name}.yaml")))["spec"]
    assert "statefulsets" not in r["includedResources"], (name, r)
st = yaml.safe_load(open(os.path.join(d, f"Restore-{b}-statefulsets.yaml")))["spec"]
assert st["includedResources"] == ["statefulsets"], st
assert st["excludedNamespaces"] == ["gibson", "tenant-acme-plugins"], st
PY
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "FAILING FIXTURE: a tenant volume the backup holds bytes for and the pods Restore did not move stops the restore (review of hosted#790)" {
  export STUB_TENANT_PVR_MISSING=1
  run "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -ne 0 ]
  assert_output_has "moved no data for: tenant-acme/tenant-acme-neo4j-0/data"
  # The gibson pods are made by Argo first, and an empty tmp volume needs none.
  # The stop names only the volume with data. The empty one is listed as not
  # checked, never as missing.
  die_line="$(printf '%s\n' "$output" | grep 'moved no data for:')"
  [[ "$die_line" != *"gibson/gibson-redis-stack-0/data"* ]]
  [[ "$die_line" != *"tenant-acme-neo4j-0/tmp"* ]]
  assert_output_has "not checked: tenant-acme/tenant-acme-neo4j-0/tmp (empty)"
  [ -z "$(line_of "apply Restore $BACKUP-statefulsets")" ]
}

@test "the volumes of the release namespace are declared: derived ones with their reason, Redis as must come back (hosted#7)" {
  run "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  assert_output_has "derived by design: gibson/gibson-gibson-workloads-0/data (the daemon volume holds only config.yaml"
  assert_output_has "derived by design: gibson/gibson-server-0/spire-data (the SPIRE server keeps its registrations in Postgres"
  assert_output_has "must come back: gibson/gibson-redis-stack-0/data has a Completed PodVolumeRestore"
  assert_output_has "not checked: gibson/gibson-gibson-workloads-0/tmp (empty)"
}

@test "FAILING FIXTURE: a Redis volume that the backup holds and no Restore moved stops the restore (hosted#7)" {
  export STUB_REDIS_PVR_MISSING=1
  run "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -ne 0 ]
  assert_output_has "no PodVolumeRestore completed for: gibson/gibson-redis-stack-0/data"
}

@test "FAILING FIXTURE: a Redis volume that the backup did not save stops the restore (hosted#7)" {
  export STUB_REDIS_PVB_FAILED=1
  run "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -ne 0 ]
  assert_output_has "did not save these volumes that must come back: gibson/gibson-redis-stack-0/data (Failed)"
}

@test "FAILING FIXTURE: a volume of the release namespace that no class names stops the restore (hosted#7)" {
  export STUB_PVB_UNCLASSIFIED=1
  run "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -ne 0 ]
  assert_output_has "no class: gibson/gibson-newthing-0/data (phase=Completed, bytes=100)"
}

@test "FAILING FIXTURE: the tenant volume check selects by the labels in the backup archive, and names each volume it leaves out (hosted#793, review of hosted#798)" {
  run "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  # Each tenant volume that the check leaves out is printed with its reason.
  assert_output_has "not checked: tenant-acme/belief-trainer-29123-24577/work (not-selected-by-the-pods-Restore(phase=Completed,bytes=4096))"
  assert_output_has "not checked: tenant-acme/belief-trainer-29123-24577/cache (not-selected-by-the-pods-Restore(phase=Failed,bytes=1000))"
  assert_output_has "not checked: tenant-acme/tenant-acme-neo4j-0/tmp (empty)"
  [[ "$output" != *"not checked: gibson/gibson-redis-stack-0"* ]]
  export STUB_PVB_EMPTY=1
  run "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -ne 0 ]
  assert_output_has "list no tenant volume with data that the pods Restore selects, not even the backup canary"
  unset STUB_PVB_EMPTY
  export STUB_NO_ARCHIVE=1
  run "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -ne 0 ]
  assert_output_has "so the pods of the backup and their labels are not known"
}

@test "FAILING FIXTURE: a failed PodVolumeBackup of a pod that the pods Restore brings back stops the restore (review of hosted#798)" {
  export STUB_PVB_LOST=1
  run "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -ne 0 ]
  assert_output_has "did not save these volumes of pods that the restore brings back: tenant-acme/tenant-acme-neo4j-1/data (Failed)"
  [ -z "$(line_of "apply Restore $BACKUP-statefulsets")" ]
}

@test "a tenant namespace that exists already is not created again" {
  export STUB_NS_EXISTS=1
  run "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  run grep -c "^apply Namespace" "$STATE/order.log"
  [ "$output" = 0 ]
}

@test "FAILING FIXTURE (row 11): a tenant namespace the operator never labels again is a loud stop after restore 3" {
  export STUB_UNLABELED_NS="tenant-acme "
  run env RESTORE_TIMEOUT=1 "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -ne 0 ]
  assert_output_has "the tenant-operator did not set gibson.zeroroot.ai/managed-by=tenant-operator on tenant-acme"
  # After the tenant records restore, never before it.
  t="$(line_of "apply Restore $BACKUP-tenants")"
  [ -n "$t" ]
  [ -z "$(line_of wait_apps)" ]
}

# ---------------------------------------------------------------------------
# Row 5 (D91): the recovery values reach the chart, and Git catches up.
# ---------------------------------------------------------------------------
@test "FAILING FIXTURE (row 5): the gibson Application carries the three derived recovery values, before the app-of-apps" {
  run "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -eq 0 ] || { echo "$output" >&2; cat "$STATE/order.log" >&2; return 1; }
  gib="$(line_of "apply-file gibson-with-recovery.yaml")"
  aoa="$(line_of "app-of-apps")"
  [ -n "$gib" ] && [ -n "$aoa" ] && [ "$gib" -lt "$aoa" ] || { cat "$STATE/order.log" >&2; return 1; }
  run python3 - "$STATE/applied/file-gibson-with-recovery.yaml" "$TREE/gitops/envs/drill/gibson.yaml" <<'PY'
import os, sys, yaml
got, base = yaml.safe_load(open(sys.argv[1])), yaml.safe_load(open(sys.argv[2]))
params = got["spec"]["sources"][0]["helm"].pop("parameters")
assert params == [
    {"name": "platformPostgres.recovery.backupID", "value": os.environ["BACKUP_ID"]},
    {"name": "platformPostgres.recovery.serverName", "value": os.environ["SOURCE_ARCHIVE"]},
    {"name": "platformPostgres.backup.serverName", "value": os.environ["RESTORE_ARCHIVE"]},
], params
# Everything else is the overlay, unchanged.
assert got == base, "the verb changed more than the parameters"
PY
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "FAILING FIXTURE (row 5): an overlay that already sets parameters on the gibson source is refused" {
  python3 - "$TREE/gitops/envs/drill/gibson.yaml" <<'PY'
import sys, yaml
p = sys.argv[1]; a = yaml.safe_load(open(p))
a["spec"]["sources"][0].setdefault("helm", {})["parameters"] = [{"name": "x", "value": "y"}]
yaml.safe_dump(a, open(p, "w"))
PY
  run "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -ne 0 ]
  assert_output_has "restore's own seam"
  [ -z "$(line_of app-of-apps)" ]
}

@test "the drill opens no catch-up PR, and the overlay and body it would write are correct" {
  run "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  assert_output_has "throwaway env: Git is not updated"
  [ ! -f "$STATE/gh.log" ]
  # The overlay copy differs from the overlay in exactly one line.
  run diff "$TREE/gitops/envs/drill/values.yaml" "$STATE/work/catch-up-bundle/values.yaml"
  [ "$(printf '%s\n' "$output" | grep -c '^[<>]')" -eq 2 ] || { echo "$output" >&2; return 1; }
  assert_output_has "serverName: \"$RESTORE_ARCHIVE\""
  body="$(cat "$STATE/work/catch-up-bundle/body.md")"
  grep -q -x "BRANCH=restore/drill-$BACKUP" "$STATE/work/catch-up-bundle/meta.env"
  [[ "$body" == *"make restore-settle ENV=drill"* ]]
  [[ "$body" == *"$RESTORE_ARCHIVE"* && "$body" == *"$SOURCE_ARCHIVE"* && "$body" == *"$BACKUP_ID"* ]]
  [[ "$body" == *"backup \`$BACKUP\`"* ]]
}

# staging_origin — the checkout becomes a clone of a bare origin, so a push
# is real and local, and gh is a stub that records the PR it would open.
staging_origin() {
  git init -q --bare "$BATS_TEST_TMPDIR/origin.git"
  cp -R "$REPO_ROOT/gitops/envs/staging" "$TREE/gitops/envs/staging"
  git -C "$TREE" init -q -b main
  git -C "$TREE" -c user.name=t -c user.email=t@t add -A
  git -C "$TREE" -c user.name=t -c user.email=t@t commit -q -m base
  git -C "$TREE" remote add origin "$BATS_TEST_TMPDIR/origin.git"
  git -C "$TREE" push -q origin main
  cat > "$STUB_DIR/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "$STATE/gh.log"
while [ $# -gt 0 ]; do case "$1" in --body-file) cp "$2" "$STATE/gh-body.md"; shift 2 ;; *) shift ;; esac; done
echo "https://github.com/zeroroot-ai/hosted/pull/4242"
SH
  chmod +x "$STUB_DIR/gh"
}

# assert_catch_up_pr — the one branch, the one line, the one PR.
assert_catch_up_pr() {
  grep -q -- "--head restore/staging-$BACKUP --base main" "$STATE/gh.log"
  grep -q "make restore-settle ENV=staging" "$STATE/gh-body.md"
  run git -C "$BATS_TEST_TMPDIR/origin.git" show "restore/staging-$BACKUP:gitops/envs/staging/values.yaml"
  [ "$status" -eq 0 ]
  assert_output_has "serverName: \"$RESTORE_ARCHIVE\""
  run git -C "$BATS_TEST_TMPDIR/origin.git" diff --stat main "restore/staging-$BACKUP"
  assert_output_has "1 file changed, 1 insertion(+), 1 deletion(-)"
}

@test "FAILING FIXTURE (row 5): a workstation restore of staging opens the catch-up PR at once, from a branch of origin main" {
  staging_origin
  run env DRIVE_ENV=staging "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  assert_output_has "restored, Git catching up: PR 4242"
  assert_catch_up_pr
}

@test "FAILING FIXTURE (hosted#687): with RESTORE_CATCH_UP_PR=later the restore writes the bundle and opens no PR" {
  staging_origin
  run env DRIVE_ENV=staging RESTORE_CATCH_UP_PR=later RESTORE_CATCH_UP_DIR="$STATE/bundle" "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  assert_output_has "the catch-up job opens the PR"
  [ ! -f "$STATE/gh.log" ]
  run git -C "$BATS_TEST_TMPDIR/origin.git" branch --list "restore/*"
  [ -z "$output" ]
  for f in meta.env values.yaml body.md; do [ -s "$STATE/bundle/$f" ]; done
  grep -q -x "BRANCH=restore/staging-$BACKUP" "$STATE/bundle/meta.env"
  grep -q -x "RESTORE_ARCHIVE_NAME=$RESTORE_ARCHIVE" "$STATE/bundle/meta.env"
  grep -q -x "GITOPS_PATH=gitops/envs/staging" "$STATE/bundle/meta.env"
}

@test "FAILING FIXTURE (hosted#687): restore-catch-up.sh opens the PR from the bundle, with the one line written into origin main" {
  staging_origin
  run env DRIVE_ENV=staging RESTORE_CATCH_UP_PR=later RESTORE_CATCH_UP_DIR="$STATE/bundle" "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  # main moved after the restore: a second line of the overlay changed. The
  # catch-up still changes one line, on top of the new main.
  sed -i 's/^\(\s*displayName:\)/\1/' "$TREE/gitops/envs/staging/values.yaml"
  printf '\n# a later commit on main\n' >> "$TREE/gitops/envs/staging/values.yaml"
  git -C "$TREE" -c user.name=t -c user.email=t@t commit -q -am "later" && git -C "$TREE" push -q origin main
  run "$TREE/scripts/restore-catch-up.sh" "$STATE/bundle"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  assert_output_has "CATCH_UP_PR=https://github.com/zeroroot-ai/hosted/pull/4242"
  assert_catch_up_pr
  run git -C "$BATS_TEST_TMPDIR/origin.git" show "restore/staging-$BACKUP:gitops/envs/staging/values.yaml"
  assert_output_has "a later commit on main"
}

@test "FAILING FIXTURE (hosted#687): a bundle whose overlay names another archive than its meta is refused" {
  staging_origin
  run env DRIVE_ENV=staging RESTORE_CATCH_UP_PR=later RESTORE_CATCH_UP_DIR="$STATE/bundle" "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -eq 0 ]
  sed -i "s/^RESTORE_ARCHIVE_NAME=.*/RESTORE_ARCHIVE_NAME=platform-postgres-somewhere-else/" "$STATE/bundle/meta.env"
  run "$TREE/scripts/restore-catch-up.sh" "$STATE/bundle"
  [ "$status" -ne 0 ]
  assert_output_has "not platform-postgres-somewhere-else"
  [ ! -f "$STATE/gh.log" ]
}

@test "the recreate workflow keeps the verb job at contents read, and only the catch-up job writes" {
  run python3 - "$REPO_ROOT/.github/workflows/recreate.yml" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
assert w["permissions"] == {"contents": "read", "id-token": "write"}, w["permissions"]
jobs = w["jobs"]
assert "permissions" not in jobs["recreate"]
cu = jobs["catch-up"]
assert cu["permissions"] == {"contents": "write", "pull-requests": "write"}, cu["permissions"]
assert cu["needs"] == "recreate" and "inputs.restore_from != ''" in cu["if"]
runs = " ".join(s.get("run", "") for s in cu["steps"])
assert "scripts/restore-catch-up.sh" in runs and "make " not in runs
mk = [s for s in jobs["recreate"]["steps"] if "make recreate" in s.get("run", "")][0]
assert mk["env"]["RESTORE_CATCH_UP_PR"] == "later"
up = [s for s in jobs["recreate"]["steps"] if "upload-artifact" in s.get("uses", "")][0]
assert up["with"]["name"] == "restore-catch-up" and up["with"]["if-no-files-found"] == "error"
PY
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Row 3 (D91): the archive gate knows the mode.
# ---------------------------------------------------------------------------
# gate_setup — a stage 0 for the gate: a keyring with the test disk seed, a
# substrate.env whose bucket is the drill overlay's, an overlay copy with the
# disk key of that seed, a bucket that is a directory, and an aws stub that
# reads it. The stub answers an s3 call only for the bucket that the overlay
# names. A key that is not in the directory is not in the bucket.
gate_setup() {
  local ov="$TREE/gitops/envs/drill/values.yaml" bucket disk_repo
  bucket="$(python3 -c 'import sys,yaml; v=yaml.safe_load(open(sys.argv[1])); print(v["platformPostgres"]["backup"]["destinationPath"].split("/")[2])' "$ov")"
  disk_repo="$(python3 -c 'import sys,yaml; v=yaml.safe_load(open(sys.argv[1])); print(v["gibson-workloads"]["setec"]["launcher"]["diskRepo"])' "$ov")"
  python3 - "$ov" "$DISK_PUBLIC_KEY" "$SOURCE_ARCHIVE" <<'PY'
import re, sys
p, key, name = sys.argv[1:4]
t = open(p).read()
t = re.sub(r'^( *)publicKeys:\n((?:\1  - .*\n)+)', lambda m: '%spublicKeys:\n%s  - "%s"\n' % (m.group(1), m.group(1), key), t, count=1, flags=re.M)
t = re.sub(r'^(\s*serverName:\s*)"[^"]*"', r'\1"%s"' % name, t, count=1, flags=re.M)
open(p, "w").write(t)
PY
  export GATE_BUCKET="$bucket"
  printf 'SETEC_DISK_SIGNING_SEED=%s\nBUCKET_ACCESS_KEY=AKIAEXAMPLEBATS00000\nBUCKET_SECRET_KEY=x\n' "$DISK_SEED" > "$STATE/keyring.env"
  cat > "$STATE/substrate.env" <<EOF
SUBSTRATE_ENV=drill
BUCKET_ENDPOINT=https://s3.us-east-1.amazonaws.com
BUCKET_REGION=us-east-1
BUCKET_NAME=$bucket
KEYRING_FILE=$STATE/keyring.env
SETEC_DISK_REPO=$disk_repo
EOF
  mkdir -p "$STATE/bucket"
  cat > "$STUB_DIR/aws" <<'SH'
#!/usr/bin/env bash
echo "aws $*" >> "$STATE/aws.log"
B="$STATE/bucket"
args=("$@")
[ "${args[0]}" = --endpoint-url ] && args=("${args[@]:2}")
set -- "${args[@]}"
case "$1 $2" in
  "s3 ls")
    k="${3#s3://$GATE_BUCKET/}"; [ "$k" != "$3" ] && [ -f "$B/$k" ] || exit 1
    echo "2026-10-12 04:00:00 12 $(basename "$k")"; exit 0 ;;
  "s3 cp")
    shift 2; [ "$1" = --no-progress ] && shift
    k="${1#s3://$GATE_BUCKET/}"; [ "$k" != "$1" ] && [ -f "$B/$k" ] || exit 1
    cp "$B/$k" "$2"; exit 0 ;;
  "s3api list-objects-v2")
    shift 2; bucket=""; prefix=""; query=""
    while [ $# -gt 0 ]; do case "$1" in --bucket) bucket="$2"; shift 2 ;; --prefix) prefix="$2"; shift 2 ;; --query) query="$2"; shift 2 ;; *) shift ;; esac; done
    [ "$bucket" = "$GATE_BUCKET" ] || { echo "NoSuchBucket: $bucket" >&2; exit 254; }
    n="$(cd "$B" && find . -type f | sed 's|^\./||' | awk -v p="$prefix" 'index($0, p) == 1' | grep -c . || true)"
    case "$query" in
      *LastModified*) echo "2026-10-01T00:00:00+00:00" ;;
      *) [ "$n" -gt 0 ] && echo 1 || echo 0 ;;
    esac
    exit 0 ;;
esac
echo "aws stub: no answer for: $*" >&2
exit 255
SH
  chmod +x "$STUB_DIR/aws"
  cat > "$BATS_TEST_TMPDIR/gate.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
HERE="$TREE/scripts"; REPO="$TREE"; SUBSTRATE_ENV="$STATE/substrate.env"; ENV_NAME=drill
GITOPS_PATH=gitops/envs/drill; RESTORE_FROM="${1:-}"; LIVE_CLUSTER_SINCE=""
log() { printf 'LOG %s\n' "$*"; }
die() { printf 'DIE %s\n' "$*" >&2; exit 1; }
. "$HERE/lib/bringup-before-cluster.sh"
echo "RESTORE_ARCHIVE_NAME=${RESTORE_ARCHIVE_NAME}"
SH
  chmod +x "$BATS_TEST_TMPDIR/gate.sh"
}

# put <key> — one object in the stub bucket.
put() { mkdir -p "$STATE/bucket/$(dirname "$1")"; printf 'x' > "$STATE/bucket/$1"; }

# arm_backup — the named Velero backup, with the CNPG record of the preserve
# teardown inside it.
arm_backup() {
  local prefix dir build
  prefix="$(python3 -c 'import sys,yaml; v=yaml.safe_load(open(sys.argv[1])) or {}; print(str((v.get("bucket") or {}).get("prefix") or "backups/velero").strip("/"))' "$TREE/gitops/envs/drill/gibson-velero-values.yaml")"
  dir="$STATE/bucket/$prefix/backups/$BACKUP"
  mkdir -p "$dir"
  printf '{"status":{"phase":"%s"}}' "${BACKUP_PHASE_IN_BUCKET:-Completed}" > "$dir/velero-backup.json"
  build="$BATS_TEST_TMPDIR/build/resources/backups.postgresql.cnpg.io/namespaces/gibson"
  mkdir -p "$build"
  printf '{"status":{"backupId":"%s","serverName":"%s"}}' "$BACKUP_ID" "$SOURCE_ARCHIVE" > "$build/$BACKUP.json"
  tar -czf "$dir/$BACKUP.tar.gz" -C "$BATS_TEST_TMPDIR/build" .
}

@test "FAILING FIXTURE (row 3): a restore accepts the full source archive and writes to the empty derived one" {
  gate_setup; arm_backup
  put "backups/postgres/$SOURCE_ARCHIVE/base/$BACKUP_ID/backup.info"
  put "backups/postgres/$SOURCE_ARCHIVE/wals/0000000100000000/000000010000000000000003.gz"
  run "$BATS_TEST_TMPDIR/gate.sh" "$BACKUP"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  assert_output_has "the source archive s3://$GATE_BUCKET/backups/postgres/$SOURCE_ARCHIVE/ holds base backup $BACKUP_ID"
  assert_output_has "s3://$GATE_BUCKET/backups/postgres/$RESTORE_ARCHIVE/ is empty"
  assert_output_has "RESTORE_ARCHIVE_NAME=$RESTORE_ARCHIVE"
}

@test "FAILING FIXTURE: a restore of a backup that Velero did not complete is refused at the gate (review of hosted#798)" {
  gate_setup; BACKUP_PHASE_IN_BUCKET=PartiallyFailed arm_backup
  put "backups/postgres/$SOURCE_ARCHIVE/base/$BACKUP_ID/backup.info"
  run "$BATS_TEST_TMPDIR/gate.sh" "$BACKUP"
  [ "$status" -ne 0 ]
  assert_output_has "backup '$BACKUP' is PartiallyFailed, not Completed"
}

@test "a fresh recreate still refuses the same full archive (row 3)" {
  gate_setup
  put "backups/postgres/$SOURCE_ARCHIVE/wals/0000000100000000/000000010000000000000003.gz"
  run "$BATS_TEST_TMPDIR/gate.sh" ""
  [ "$status" -ne 0 ]
  assert_output_has "already holds WAL from an earlier cluster"
}

@test "FAILING FIXTURE (row 3): a restore whose source archive lacks the named base backup is refused" {
  gate_setup; arm_backup
  put "backups/postgres/$SOURCE_ARCHIVE/base/20261001T000000/backup.info"
  run "$BATS_TEST_TMPDIR/gate.sh" "$BACKUP"
  [ "$status" -ne 0 ]
  assert_output_has "holds nothing. Postgres would have nothing to recover from"
}

@test "FAILING FIXTURE (row 3): a restore whose derived archive already holds WAL is refused" {
  gate_setup; arm_backup
  put "backups/postgres/$SOURCE_ARCHIVE/base/$BACKUP_ID/backup.info"
  put "backups/postgres/$RESTORE_ARCHIVE/wals/0000000100000000/000000020000000000000004.gz"
  run "$BATS_TEST_TMPDIR/gate.sh" "$BACKUP"
  [ "$status" -ne 0 ]
  assert_output_has "an earlier restore of the same backup wrote it"
}

@test "a restore of a restore archive does not grow the name" {
  run bash -c ". '$REPO_ROOT/scripts/lib/velero-restore.sh'; restore_archive_name platform-postgres-20261012-r20261012T040000 20261019T040000"
  [ "$output" = "platform-postgres-20261012-r20261019T040000" ]
}

# ---------------------------------------------------------------------------
# restore-settle (D91): Git is the truth again, and only when it is.
# ---------------------------------------------------------------------------
# settle_setup <archive-in-git> [param names] — a git checkout with the
# overlay at one commit, and a kubectl stub that answers only Application
# argocd/gibson and Cluster gibson/platform-postgres.
settle_setup() {
  local archive="$1"
  export SETTLE_PARAMS="${2:-platformPostgres.recovery.backupID platformPostgres.recovery.serverName platformPostgres.backup.serverName}"
  git init -q --bare "$BATS_TEST_TMPDIR/origin.git"
  git -C "$TREE" init -q -b main
  sed -i -E "s/^(\s*serverName:\s*)\"[^\"]*\"/\1\"$archive\"/" "$TREE/gitops/envs/drill/values.yaml"
  git -C "$TREE" -c user.name=t -c user.email=t@t add -A
  git -C "$TREE" -c user.name=t -c user.email=t@t commit -q -m overlay
  git -C "$TREE" remote add origin "$BATS_TEST_TMPDIR/origin.git"
  git -C "$TREE" push -q origin main
  export SETTLE_REV="$(git -C "$TREE" rev-parse HEAD)"
  cat > "$STUB_DIR/kubectl" <<'SH'
#!/usr/bin/env bash
args="$*"
echo "kubectl $args" >> "$STATE/kubectl.log"
patched() { [ -f "$STATE/patched" ]; }
case "$args" in
  "-n argocd get application gibson -o json")
    python3 - <<'PY'
import json, os
names = os.environ["SETTLE_PARAMS"].split()
vals = {"platformPostgres.backup.serverName": os.environ["RESTORE_ARCHIVE"]}
# After the patch the spec and the compare hold no parameter.
if os.path.exists(os.path.join(os.environ["STATE"], "patched")):
    names = []
params = [{"name": n, "value": vals.get(n, "v")} for n in names]
print(json.dumps({"spec": {"sources": [
    {"chart": "gibson", "helm": {"parameters": params}},
    {"repoURL": "https://github.com/zeroroot-ai/hosted", "ref": "values"}]},
  "status": {"sync": {"status": "Synced", "revisions": ["0.146.1", os.environ["SETTLE_REV"]],
                      "comparedTo": {"sources": [{"chart": "gibson", "helm": {"parameters": params}}]}},
             "health": {"status": "Healthy"}}}))
PY
    exit 0 ;;
  "-n argocd patch application gibson --type json -p "*) touch "$STATE/patched"; exit 0 ;;

  "-n gibson get cluster.postgresql.cnpg.io platform-postgres -o jsonpath={.spec.backup.barmanObjectStore.serverName}")
    patched && printf '%s' "$(sed -n -E 's/^\s*serverName:\s*"([^"]*)".*/\1/p' "$TREE/gitops/envs/drill/values.yaml" | head -1)" || printf '%s' "$RESTORE_ARCHIVE"
    exit 0 ;;
esac
echo "Error from server (NotFound): kubectl stub: no object for: $args" >&2
exit 1
SH
  chmod +x "$STUB_DIR/kubectl"
}

@test "FAILING FIXTURE (D91): restore-settle refuses while Git at the rendered revision names another archive" {
  settle_setup "$SOURCE_ARCHIVE"
  run env SETTLE_POLL=0 "$TREE/scripts/restore-settle.sh" drill
  [ "$status" -ne 0 ]
  assert_output_has "Merge the catch-up PR"
  [ ! -f "$STATE/patched" ]
}

@test "restore-settle removes the three parameters once Git names the live archive" {
  settle_setup "$RESTORE_ARCHIVE"
  run env SETTLE_POLL=0 "$TREE/scripts/restore-settle.sh" drill
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ -f "$STATE/patched" ]
  grep -q 'remove","path":"/spec/sources/0/helm/parameters' "$STATE/kubectl.log"
  assert_output_has "Git is the truth again"
}

@test "FAILING FIXTURE (D91): restore-settle refuses a parameter set that is not the three of D91" {
  settle_setup "$RESTORE_ARCHIVE" "platformPostgres.backup.serverName global.domain"
  run env SETTLE_POLL=0 "$TREE/scripts/restore-settle.sh" drill
  [ "$status" -ne 0 ]
  assert_output_has "Refusing to remove them blind"
  [ ! -f "$STATE/patched" ]
}

@test "the edge certificate is read back after the keyring and before the first Application, in a restore" {
  run "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  grep -qx keyring "$STATE/order.log"
  grep -qx edge-cert "$STATE/order.log"
  [ "$(grep -nx keyring "$STATE/order.log" | cut -d: -f1)" -lt "$(grep -nx edge-cert "$STATE/order.log" | cut -d: -f1)" ]
  first_app="$(grep -n '^apply' "$STATE/order.log" | head -1 | cut -d: -f1)"
  [ -z "$first_app" ] || [ "$(grep -nx edge-cert "$STATE/order.log" | cut -d: -f1)" -lt "$first_app" ]
  assert_output_has "holds nothing yet; cert-manager issues one"
}

@test "FAILING FIXTURE: a substrate.env with no edge certificate secret stops the bringup and names the fix" {
  printf 'SUBSTRATE_ENV=drill\n' > "$STATE/substrate.env"
  run "$BATS_TEST_TMPDIR/drive.sh" "$BACKUP"
  [ "$status" -ne 0 ]
  assert_output_has "names no EDGE_CERT_SECRET. Run make substrate ENV=drill"
}

# ---------------------------------------------------------------------------
# settle-probe (hosted#687): the drill proves that the two recovery
# parameters can leave a running Cluster.
# ---------------------------------------------------------------------------
# probe_setup — a kubectl stub for a restored drill. Knobs: STUB_PROBE_AFTER
# (initdb | recovery: what the Cluster reports after the patch) and
# STUB_PROBE_UID_AFTER (the primary pod UID after the patch).
probe_setup() {
  export STUB_PROBE_AFTER="${1:-initdb}" STUB_PROBE_UID_AFTER="${2:-uid-primary-1}"
  export STUB_PROBE_PARAMS="${3:-platformPostgres.recovery.backupID platformPostgres.recovery.serverName platformPostgres.backup.serverName}"
  cat > "$STUB_DIR/kubectl" <<'SH'
#!/usr/bin/env bash
args="$*"
echo "kubectl $args" >> "$STATE/kubectl.log"
patched() { [ -f "$STATE/patched" ]; }
# The Cluster changes only after Argo compared the new parameters.
applied() { patched && { [ -z "${STUB_COMPARE_LAG:-}" ] || [ -f "$STATE/compared" ]; }; }
case "$args" in
  "-n argocd get application gibson -o jsonpath={range .spec.sources[0].helm.parameters[*]}{.name}{\" \"}{end}")
    if patched; then printf 'platformPostgres.backup.serverName '; else for n in $STUB_PROBE_PARAMS; do printf '%s ' "$n"; done; fi; exit 0 ;;
  # The whole Application, one read per pass of settle_wait. STUB_COMPARE_LAG=N:
  # the first N reads after the patch still hold the compare of the old
  # names, Synced, and the Cluster still has its recovery until Argo has
  # compared the new ones (audit of the restore path).
  "-n argocd get application gibson -o json")
    old="$STUB_PROBE_PARAMS"; new="platformPostgres.backup.serverName"; spec="$old"; cmp="$old"
    if patched; then
      spec="$new"; c=$(( $(cat "$STATE/compare-reads" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$STATE/compare-reads"
      if [ "$c" -gt "${STUB_COMPARE_LAG:-0}" ]; then cmp="$new"; touch "$STATE/compared"; fi
    fi
    SPEC="$spec" CMP="$cmp" python3 -c '
import json, os
p = lambda v: [{"name": n, "value": "v"} for n in v.split()]
print(json.dumps({"spec": {"sources": [{"chart": "gibson", "helm": {"parameters": p(os.environ["SPEC"])}}]},
  "status": {"sync": {"status": "Synced", "comparedTo": {"sources": [{"chart": "gibson", "helm": {"parameters": p(os.environ["CMP"])}}]}},
             "health": {"status": "Healthy"}}}))'
    exit 0 ;;
  "-n argocd patch application gibson --type json -p "*)
    printf '%s' "$args" > "$STATE/patch.txt"; touch "$STATE/patched"; exit 0 ;;
  "-n gibson get cluster.postgresql.cnpg.io platform-postgres -o jsonpath={.spec.backup.barmanObjectStore.serverName}")
    printf '%s' "$RESTORE_ARCHIVE"; exit 0 ;;
  "-n gibson get cluster.postgresql.cnpg.io platform-postgres -o jsonpath={.status.currentPrimary}") printf 'platform-postgres-1'; exit 0 ;;
  "-n gibson get pod platform-postgres-1 -o jsonpath={.metadata.uid}")
    patched && printf '%s' "$STUB_PROBE_UID_AFTER" || printf 'uid-primary-1'; exit 0 ;;
  "-n gibson get cluster.postgresql.cnpg.io platform-postgres -o jsonpath={.spec.bootstrap.recovery.source}")
    if applied && [ "$STUB_PROBE_AFTER" = initdb ]; then exit 0; fi; printf 'platform-postgres-archive'; exit 0 ;;
  "-n gibson get cluster.postgresql.cnpg.io platform-postgres -o jsonpath={.spec.bootstrap.initdb.database}")
    if applied && [ "$STUB_PROBE_AFTER" = initdb ]; then printf 'postgres'; fi; exit 0 ;;
  "-n gibson get cluster.postgresql.cnpg.io platform-postgres -o jsonpath={.spec.externalClusters[*].name}")
    if applied && [ "$STUB_PROBE_AFTER" = initdb ]; then exit 0; fi; printf 'platform-postgres-archive'; exit 0 ;;
  "-n gibson get cluster.postgresql.cnpg.io platform-postgres -o jsonpath={range .status.conditions[?(@.type=='ContinuousArchiving')]}{.status}{end}")
    printf 'True'; exit 0 ;;
esac
echo "Error from server (NotFound): kubectl stub: no object for: $args" >&2
exit 1
SH
  chmod +x "$STUB_DIR/kubectl"
}

@test "FAILING FIXTURE (hosted#687): the probe removes the two recovery parameters, by name, and proves initdb, no externalClusters and the same primary" {
  probe_setup initdb
  run env SETTLE_POLL=0 "$TREE/test/dr/settle-probe.sh"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  grep -q '"op":"test","path":"/spec/sources/0/helm/parameters/0/name","value":"platformPostgres.recovery.backupID"' "$STATE/patch.txt"
  grep -q '"op":"test","path":"/spec/sources/0/helm/parameters/0/name","value":"platformPostgres.recovery.serverName"' "$STATE/patch.txt"
  [ "$(grep -o '"op":"remove","path":"/spec/sources/0/helm/parameters/0"' "$STATE/patch.txt" | wc -l)" -eq 2 ]
  ! grep -q 'backup.serverName' "$STATE/patch.txt" || { echo "a line that must not be there matched"; false; }
  assert_output_has "the recovery parameters left a running Cluster"
}

@test "FAILING FIXTURE: the probe waits until Argo compared the new parameters, not for a Synced of the old ones (audit of hosted#687)" {
  # Right after the patch the status still holds the compare of the old
  # parameters: Synced, Healthy, the same archive. The Cluster still has its
  # recovery until Argo renders and applies the change.
  export STUB_COMPARE_LAG=3
  probe_setup initdb
  run env SETTLE_POLL=0 "$TREE/test/dr/settle-probe.sh"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ "$(cat "$STATE/compare-reads")" -ge 4 ]
  assert_output_has "the recovery parameters left a running Cluster"
}

@test "FAILING FIXTURE (hosted#687): a Cluster that keeps bootstrap.recovery after the patch fails the probe" {
  probe_setup recovery
  run env SETTLE_POLL=0 "$TREE/test/dr/settle-probe.sh"
  [ "$status" -ne 0 ]
  assert_output_has "the CNPG webhook refused the change, or Argo did not apply it"
}

@test "FAILING FIXTURE (hosted#687): a primary pod with a new UID after the patch fails the probe" {
  probe_setup initdb uid-primary-2
  run env SETTLE_POLL=0 "$TREE/test/dr/settle-probe.sh"
  [ "$status" -ne 0 ]
  assert_output_has "the removal restarted Postgres"
}

@test "FAILING FIXTURE (hosted#687): the probe refuses an Application whose parameters are not the three of D91" {
  probe_setup initdb uid-primary-1 "platformPostgres.backup.serverName"
  run env SETTLE_POLL=0 "$TREE/test/dr/settle-probe.sh"
  [ "$status" -ne 0 ]
  assert_output_has "This probe runs only on a restored drill"
  [ ! -f "$STATE/patched" ]
}
