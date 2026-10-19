#!/usr/bin/env bats
#
# recreate.bats — proves `make recreate` FAILS CLOSED (deploy#1737,
# ADR-0083).
#
# WHY THIS SUITE EXISTS
# ---------------------
# The recreate verb touches the one dev cluster and the one estate, so the
# refusals that fire BEFORE it starts are what stop it touching the wrong
# one: no ENV, and an ENV with no recreate row.
#
# The restore half of the verb has its own suite, tests/harness/restore.bats
# (deploy#1739): a name that matches no backup, a nameless recreate that
# must restore nothing, and the order the three restores run in.
#
# Offline, by construction: every refusal under test fires before preflight,
# so no substrate, cluster or network is touched.
#
# Run:
#   bats tests/harness/recreate.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
# The kind verb refuses to start without chart source (ADR-0086); the
# refusals under test fire before that, but a worktree has no ../charts,
# so the suite points the verb at the same sibling default it uses itself.
export CHARTS_ROOT="${CHARTS_ROOT:-$REPO_ROOT/../charts}"
DISK_SEED="nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A="
DISK_PUBLIC_KEY="11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="

setup() {
  # A stage 0 shape for the AWS arm. Nothing here reaches AWS: the two tests
  # that use it assert on refusals that happen before the first cloud call.
  KEYRING_AWS="$BATS_TEST_TMPDIR/keyring.env"
  SUBSTRATE_AWS="$BATS_TEST_TMPDIR/substrate-staging.env"
  # The disk seed is RFC 8032 test vector 1, so its public key is known.
  printf 'OPENBAO_SEAL_KEY=x\nSETEC_DISK_SIGNING_SEED=%s\n' "$DISK_SEED" > "$KEYRING_AWS"

  # Every tool the AWS recreate requires, stubbed. Without this the suite
  # measures the RUNNER's image rather than the verb: a runner without
  # terraform stops at the tool check, long before the assertion under test,
  # and the test passes or fails for the wrong reason. `aws` denies, so the
  # suite can never reach an account even by accident; the rest are inert.
  AWS_STUBS="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$AWS_STUBS"
  for t in kubectl terraform curl helm; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$AWS_STUBS/$t"
    chmod +x "$AWS_STUBS/$t"
  done
  # python3 is REAL. The verb parses the env overlay with it, and an inert
  # stub makes that parse return nothing — which the archive gate then reads
  # as an overlay with no values in it, for every test in the suite.
  printf '#!/usr/bin/env bash\nexec %s "$@"\n' "$(command -v python3)" > "$AWS_STUBS/python3"
  chmod +x "$AWS_STUBS/python3"
  # skopeo answers the --all check of scripts/lib/skopeo.sh and refuses any
  # other call, so no test depends on the skopeo of the machine.
  cat > "$AWS_STUBS/skopeo" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "copy --help") printf '  -a, --all    Copy all images if SOURCE-IMAGE is a list\n'; exit 0 ;;
esac
echo "skopeo stub: no registry in this suite" >&2
exit 1
STUB
  chmod +x "$AWS_STUBS/skopeo"
  # `aws` denies everything EXCEPT the one read the archive gate makes. That
  # gate runs before the cloud-credential check, so a blanket deny would stop
  # every test on the gate rather than on the refusal it is measuring.
  # STUB_ARCHIVE_OBJECTS is how many objects the archive directory holds.
  cat > "$AWS_STUBS/aws" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  # The EC2 recreate asks whether the CLI has the ssm command.
  "ssm help") exit 0 ;;
  # The live cluster of the env (hosted#624): STUB_LIVE_SINCE is its creation
  # time, unset means no cluster is up.
  *"ec2 describe-instances"*|*"eks describe-cluster"*)
    [ -n "${STUB_LIVE_SINCE:-}" ] || exit 254
    echo "$STUB_LIVE_SINCE"; exit 0 ;;
  # The oldest object of the archive directory.
  *"s3api list-objects-v2"*"min(Contents[].LastModified)"*)
    echo "${STUB_ARCHIVE_OLDEST:-2026-01-01T00:00:00+00:00}"; exit 0 ;;
  *"s3api list-objects-v2"*)
    n="${STUB_ARCHIVE_OBJECTS:-0}"
    # The real CLI, faithfully. An EMPTY prefix has no Contents key at all,
    # so `length(Contents)` raises "invalid type for value: None" and the CLI
    # exits non-zero — on exactly the case the gate exists to allow. Only a
    # query that supplies the empty list survives it.
    if [ "$n" = 0 ] && ! printf '%s' "$*" | grep -q 'Contents ||'; then
      echo "In function length(), invalid type for value: None, expected one of: ['string', 'array', 'object'], received: \"null\"" >&2
      exit 255
    fi
    # --max-items is the CLI's OWN paginator, not the S3 bound: when it
    # truncates it prints the query result and then a second line. --max-keys
    # is the server-side bound and prints one.
    case "$*" in *--max-items*) printf '%s\n0\n' "$n"; exit 0 ;; esac
    echo "$n"; exit 0 ;;
esac
exit 1
STUB
  chmod +x "$AWS_STUBS/aws"
  # BUCKET_NAME is DERIVED from the staging overlay, not written here. The gate
  # now refuses a bringup whose overlay names a different bucket from the
  # substrate's, and a hard-coded fixture value drifted from the overlay the
  # moment either moved — which is how this fixture came to declare
  # ...-000000000000 against an overlay saying ...-447184491447. Nothing
  # compared them, so nothing noticed.
  bucket="$(python3 - "$REPO_ROOT/gitops/envs/staging/values.yaml" <<'PYBUCKET'
import sys, yaml
v = yaml.safe_load(open(sys.argv[1])) or {}
dest = (((v.get("platformPostgres") or {}).get("backup") or {}).get("destinationPath") or "")
print(dest.removeprefix("s3://").split("/")[0])
PYBUCKET
)"
  [ -n "$bucket" ] || { echo "setup: could not read the staging overlay's destinationPath bucket" >&2; return 1; }
  disk_repo="$(python3 - "$REPO_ROOT/gitops/envs/staging/values.yaml" <<'PYDISK'
import sys, yaml
v = yaml.safe_load(open(sys.argv[1])) or {}
print((((v.get("gibson-workloads") or {}).get("setec") or {}).get("launcher") or {}).get("diskRepo") or "")
PYDISK
)"
  [ -n "$disk_repo" ] || { echo "setup: could not read the staging overlay's setec diskRepo" >&2; return 1; }
  cat > "$SUBSTRATE_AWS" <<EOF
SUBSTRATE_ENV=staging
BUCKET_ENDPOINT=https://s3.us-east-1.amazonaws.com
BUCKET_NAME=$bucket
KEYRING_FILE=$KEYRING_AWS
SETEC_DISK_REPO=$disk_repo
EOF

  # The staging overlay holds the disk public key of the real staging
  # keyring, not the key of the fixture seed, so the disk gate refuses it, as
  # it must. The tests that measure a LATER gate read a copy of the overlay
  # whose key list is the key of the fixture seed. GITOPS_PATH is the overlay
  # the verb reads. The copy lives under the test's own temporary directory,
  # never in the repo tree, so a killed run leaves nothing beside the real
  # overlays. The verb joins GITOPS_PATH to the repo root, so the path is
  # relative to it. The copy replaces the key list whatever it holds, so a
  # key change in the real overlay changes nothing here.
  mkdir -p "$BATS_TEST_TMPDIR/overlay"
  python3 - "$REPO_ROOT/gitops/envs/staging/values.yaml" "$BATS_TEST_TMPDIR/overlay/values.yaml" "$DISK_PUBLIC_KEY" <<'PYKEYS' \
    || { echo "setup: the staging overlay has no setec disk key list to replace" >&2; return 1; }
import re, sys
src, dst, key = sys.argv[1:4]
text = open(src).read()
pat = re.compile(r'^( *)publicKeys:\n((?:\1  - .*\n)+)', re.M)
m = pat.search(text)
if not m:
    sys.exit(1)
text = text[:m.start()] + '%spublicKeys:\n%s  - "%s"\n' % (m.group(1), m.group(1), key) + text[m.end():]
open(dst, 'w').write(text)
PYKEYS
  # The verb reads the Velero prefix from the same overlay (hosted#593).
  cp "$REPO_ROOT/gitops/envs/staging/gibson-velero-values.yaml" "$BATS_TEST_TMPDIR/overlay/"
  GITOPS_PATH="$(realpath --relative-to="$REPO_ROOT" "$BATS_TEST_TMPDIR/overlay")"
  export GITOPS_PATH
}

@test "recreate with no ENV is refused: ENV has no default" {
  run make -C "$REPO_ROOT" recreate
  [ "$status" -ne 0 ]
  [[ "$output" == *"ENV is required and has no default"* ]]
}

# hosted#404. The eks-* targets used to inherit `ENV ?= prod`, so a target
# with no ENV acted on prod.
@test "FAILING FIXTURE: each eks-* target with no ENV is refused" {
  count=0
  for target in eks-init eks-plan eks-kubeconfig eks-converge eks-smoke; do
    run env -u ENV make -C "$REPO_ROOT" "$target"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ENV is required and has no default"* ]]
    count=$((count + 1))
  done
  [ "$count" -eq 5 ]
}

@test "no line in the Makefile gives ENV a default" {
  run grep -nE '^[[:space:]]*(export[[:space:]]+)?ENV[[:space:]]*(\?=|:=|=)' "$REPO_ROOT/Makefile"
  [ "$status" -eq 1 ]
}

@test "an ENV with no recreate row is refused and the three rows are named" {
  run make -C "$REPO_ROOT" recreate ENV=azure
  [ "$status" -ne 0 ]
  [[ "$output" == *"ENV=azure has no recreate in this repo (kind, staging, drill, prod)"* ]]
}

# hosted#406. The dev environment and its cluster lock are deleted.
@test "the dev environment and the dev lock do not come back" {
  [ ! -e "$REPO_ROOT/gitops/envs/dev" ]
  [ ! -e "$REPO_ROOT/scripts/dev-lock.sh" ]
  run grep -nE 'dev-claim|dev-release|dev-lock|DEV_LOCK' "$REPO_ROOT/Makefile"
  [ "$status" -eq 1 ]
}

# A RESTORE_FROM that is not a backup name is refused BEFORE the bucket is
# read, and long before a forty-minute apply (ADR-0083, deploy#1746). The
# shape is the one a preserve teardown prints.
@test "the AWS recreate refuses a RESTORE_FROM that is not a backup name" {
  PATH="$AWS_STUBS:$PATH" run env RESTORE_FROM='Preserve Staging/../etc' \
      "$REPO_ROOT/scripts/recreate-aws.sh" "$SUBSTRATE_AWS" staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a backup name"* ]]
  # It never reached AWS: the name check comes before the first cloud call.
  [[ "$output" != *"no usable AWS credentials"* ]]
}

@test "FIXTURE: the AWS recreate with no RESTORE_FROM reads no backup at all" {
  # A bringup with no name bootstraps every store empty, always (ADR-0083).
  # `aws` denies, so the stop is on the cloud credential — never on a bucket
  # read that should not have happened.
  PATH="$AWS_STUBS:$PATH" run env -u RESTORE_FROM \
      "$REPO_ROOT/scripts/recreate-aws.sh" "$SUBSTRATE_AWS" staging
  [ "$status" -ne 0 ]
  [[ "$output" != *"looking for backup"* ]]
  [[ "$output" == *"no usable AWS credentials"* ]]
}

# The app-of-apps is held back for exactly one window: a restore. On an empty
# bringup the variable is never passed, so stage 2 is the ordinary path
# (ADR-0027: the seam is a bringup order, not a second codepath).
@test "the app-of-apps is held back only on a restore" {
  grep -q 'bootstrap_app_of_apps=false' "$REPO_ROOT/scripts/recreate-aws.sh"
  # It appears exactly once, inside the RESTORE_FROM branch.
  [ "$(grep -c 'bootstrap_app_of_apps' "$REPO_ROOT/scripts/recreate-aws.sh")" -ge 1 ]
  # and the terraform default is true, so any other caller gets stage 2.
  grep -q 'default     = true' "$REPO_ROOT/bootstrap/eks/gibson/variables.tf"
}

# The stall detector is ONE implementation for every substrate
# (scripts/lib/wait-apps.sh, deploy#1746). Both verbs source it, and neither
# carries a private copy — a second copy is how the AWS arm came to measure
# only the Application count while kind had already learned to count pod
# movement too.
@test "every recreate arm shares one stall detector, and none redefines it" {
  grep -q 'lib/wait-apps.sh' "$REPO_ROOT/scripts/recreate-kind.sh"
  # The AWS and plain-cluster arms reach it through the shared tail.
  grep -q 'lib/wait-apps.sh' "$REPO_ROOT/scripts/lib/bringup-after-cluster.sh"
  [ "$(grep -c '^wait_apps() {' "$REPO_ROOT/scripts/recreate-kind.sh")" -eq 0 ]
  [ "$(grep -c '^wait_apps() {' "$REPO_ROOT/scripts/recreate-aws.sh")" -eq 0 ]
  [ "$(grep -c '^wait_apps() {' "$REPO_ROOT/scripts/recreate-ec2.sh")" -eq 0 ]
  [ "$(grep -c '^wait_apps() {' "$REPO_ROOT/scripts/lib/wait-apps.sh")" -eq 1 ]
}

# The two AWS arms differ ONLY in the cluster. Everything else is one copy
# (hosted#159). A step that reappears in an arm is a second implementation
# that will drift, which is how the stall detector went wrong before.
@test "the two AWS recreate arms share the pre-cluster and post-cluster halves" {
  for arm in recreate-aws.sh recreate-ec2.sh; do
    grep -q 'lib/bringup-before-cluster.sh' "$REPO_ROOT/scripts/$arm"
    grep -q 'lib/bringup-after-cluster.sh' "$REPO_ROOT/scripts/$arm"
    # Neither arm carries its own copy of a shared step.
    [ "$(grep -c '^assert_empty_pg_archive() {' "$REPO_ROOT/scripts/$arm")" -eq 0 ]
    [ "$(grep -c '^apply_overlay_app() {' "$REPO_ROOT/scripts/$arm")" -eq 0 ]
  done
  [ "$(grep -c '^assert_empty_pg_archive() {' "$REPO_ROOT/scripts/lib/bringup-before-cluster.sh")" -eq 1 ]
  [ "$(grep -c '^apply_overlay_app() {' "$REPO_ROOT/scripts/lib/bringup-after-cluster.sh")" -eq 1 ]
}

# FAILING FIXTURE: the shared tail refuses a caller that did not define the
# two substrate hooks, instead of failing half way through a bringup.
@test "FIXTURE: the shared tail refuses a caller with no substrate hooks" {
  run bash -c '
    HERE="'"$REPO_ROOT"'/scripts"
    die() { echo "$*" >&2; exit 1; }
    . "$HERE/lib/bringup-after-cluster.sh"
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs the stage1_enable_app_of_apps hook"* ]]
}

# Staging builds the plain cluster and production builds EKS. A row that
# points at the wrong stage 1 is a recreate that stands up one estate and a
# teardown that destroys another.
@test "the staging verbs drive the plain cluster and the prod verbs drive EKS" {
  grep -qE '^RECREATE_UP_staging *:= *scripts/recreate-ec2\.sh' "$REPO_ROOT/Makefile"
  grep -qE '^TEARDOWN_DOWN_staging *:= *scripts/teardown-ec2\.sh' "$REPO_ROOT/Makefile"
  grep -qE '^RECREATE_UP_prod *:= *scripts/recreate-aws\.sh' "$REPO_ROOT/Makefile"
  grep -qE '^TEARDOWN_DOWN_prod *:= *scripts/teardown-aws\.sh' "$REPO_ROOT/Makefile"
}

# The plain-cluster arm never publishes the Kubernetes API. It reads the
# kubeconfig and reaches the API through SSM, so an operator with no AWS
# credential reaches nothing.
@test "the plain-cluster recreate reaches the API only through SSM" {
  # The forward lives in scripts/lib/ssm-forward.sh since hosted#283, and the
  # three steps around it (read the kubeconfig over SSM, rewrite the server,
  # open the forward) live in scripts/lib/ec2-cluster-access.sh since ADR-0095,
  # because the recreate, the teardown and the connect verb all need them and
  # the first two had already drifted. tests/harness/ssm-forward.bats proves
  # nothing forwards outside the helper.
  #
  # This asserts the PROPERTY, not the call site: the recreate reaches the API
  # through the shared access path, and that path is what forwards. Pinning the
  # line `ssm_forward_start "$INSTANCE_ID"` inside this file is what made this
  # test fail when the call moved into the shared lib, which is a defect in the
  # test and not in the move.
  grep -q 'AWS-StartPortForwardingSession' "$REPO_ROOT/scripts/lib/ssm-forward.sh"
  grep -q 'ec2_cluster_connect "\$INSTANCE_ID"' "$REPO_ROOT/scripts/recreate-ec2.sh"
  grep -q 'ssm_forward_start ' "$REPO_ROOT/scripts/lib/ec2-cluster-access.sh"
  [ "$(grep -c 'api_allow_cidrs *= *\[\]' "$REPO_ROOT/bootstrap/ec2/gibson/envs/staging.tfvars")" -eq 1 ]
}

# FAILING FIXTURE: the property that made the AWS copy wrong. A detector that
# reads only the Application count calls a converging cluster stuck.
@test "FIXTURE: the stall fingerprint counts pod movement, not only Applications" {
  grep -q 'kubectl get pods -A' "$REPO_ROOT/scripts/lib/wait-apps.sh"
  # Finished pods are excluded, or a per-minute CronJob makes any cluster look
  # busy for ever and the stall clock never fires.
  grep -qE 'Completed.*Succeeded|Succeeded.*Completed' "$REPO_ROOT/scripts/lib/wait-apps.sh"
}

# ---------------------------------------------------------------------------
# The Postgres archive gate (2026-09-14).
#
# The durable bucket outlives the cluster by design (ADR-0083), so the SECOND
# bringup into one bucket meets the first one's WAL.
# barman-cloud-check-wal-archive refuses that directory, ContinuousArchiving
# goes False on the first archive_command, and every base backup sits in
# walArchivingFailing. CNPG still reports the Cluster Ready and Argo still
# reports the Application Healthy, so the bringup looks like a clean one-shot
# and the environment has NO backups. Measured on the staging bucket
# 2026-09-14: 12 objects under backups/postgres/platform-postgres/ survived
# the teardown, exactly as ADR-0083 intends.
#
# The gate refuses that bringup before terraform spends twenty minutes on it.
# ---------------------------------------------------------------------------
@test "a bringup whose Postgres archive already holds WAL is refused, before terraform" {
  PATH="$AWS_STUBS:$PATH" run env -u RESTORE_FROM STUB_ARCHIVE_OBJECTS=12 \
      "$REPO_ROOT/scripts/recreate-aws.sh" "$SUBSTRATE_AWS" staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"already holds WAL from an earlier cluster"* ]]
  [[ "$output" == *"platformPostgres.backup.serverName"* ]]
  # Before the cluster credential, so before any apply.
  [[ "$output" != *"no usable AWS credentials"* ]]
  # It never tells anyone to delete the old archive.
  [[ "$output" == *"Never delete the old archive"* ]]
}

# FAILING FIXTURE: the overlay names a DIFFERENT bucket from the substrate's.
#
# The gate lists $BUCKET_NAME (substrate.env, a terraform output) with a prefix
# parsed from the overlay. Those were two sources for one fact and nothing
# compared them, so a gate could prove a directory empty in the substrate's
# bucket while the chart archived into another one — and pass. The cluster then
# comes up Healthy with no backups, which is the exact failure the gate exists
# to stop, reached through the gate itself.
@test "an overlay that names a different bucket from the substrate is refused" {
  overlay="$REPO_ROOT/$GITOPS_PATH/values.yaml"
  cp "$overlay" "$BATS_TEST_TMPDIR/values.yaml.orig"
  sed -i 's|destinationPath: "s3://[^/]*/|destinationPath: "s3://somebody-elses-bucket/|' "$overlay"
  grep -q 'somebody-elses-bucket' "$overlay"
  PATH="$AWS_STUBS:$PATH" run env -u RESTORE_FROM STUB_ARCHIVE_OBJECTS=0 \
      "$REPO_ROOT/scripts/recreate-aws.sh" "$SUBSTRATE_AWS" staging
  cp "$BATS_TEST_TMPDIR/values.yaml.orig" "$overlay"
  [ "$status" -ne 0 ]
  [[ "$output" == *"somebody-elses-bucket"* ]]
  [[ "$output" == *"come up Healthy with no backups"* ]]
  # It refuses BEFORE listing, so an empty stub cannot wave it through.
  [[ "$output" != *"is empty, so this bringup can archive"* ]]
}

# The refusal names the verb that fixes it, not a YAML edit to perform by hand.
@test "the used-archive refusal names the stamp verb" {
  PATH="$AWS_STUBS:$PATH" run env -u RESTORE_FROM STUB_ARCHIVE_OBJECTS=12 \
      "$REPO_ROOT/scripts/recreate-aws.sh" "$SUBSTRATE_AWS" staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"make stamp-pg-archive ENV=staging"* ]]
}

@test "an empty archive lets the bringup through the gate" {
  PATH="$AWS_STUBS:$PATH" run env -u RESTORE_FROM STUB_ARCHIVE_OBJECTS=0 \
      "$REPO_ROOT/scripts/recreate-aws.sh" "$SUBSTRATE_AWS" staging
  [[ "$output" == *"is empty, so this bringup can archive"* ]]
  # and the run then stops where it stopped before this gate existed.
  [[ "$output" == *"no usable AWS credentials"* ]]
}

# ---------------------------------------------------------------------------
# The setec disk gate (D85, hosted#521). The overlay names the disk registry
# and the public key of the keyring seed as reviewed commits, so the bringup
# compares both with stage 0 before it builds anything.
# ---------------------------------------------------------------------------
@test "FAILING FIXTURE: the overlay as committed, with the key of another keyring, is refused and the refusal prints the key to commit" {
  PATH="$AWS_STUBS:$PATH" run env -u RESTORE_FROM STUB_ARCHIVE_OBJECTS=0 \
      GITOPS_PATH=gitops/envs/staging \
      "$REPO_ROOT/scripts/recreate-aws.sh" "$SUBSTRATE_AWS" staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"none is the key of the keyring seed SETEC_DISK_SIGNING_SEED"* ]]
  [[ "$output" == *"$DISK_PUBLIC_KEY"* ]]
  [[ "$output" != *"no usable AWS credentials"* ]]
}

@test "FAILING FIXTURE: an overlay key of another seed is refused" {
  other="$(head -c 32 /dev/zero | base64 -w0)"
  sed -i "s|^SETEC_DISK_SIGNING_SEED=.*|SETEC_DISK_SIGNING_SEED=$other|" "$KEYRING_AWS"
  PATH="$AWS_STUBS:$PATH" run env -u RESTORE_FROM STUB_ARCHIVE_OBJECTS=0 \
      "$REPO_ROOT/scripts/recreate-aws.sh" "$SUBSTRATE_AWS" staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"none is the key of the keyring seed"* ]]
}

@test "FAILING FIXTURE: an overlay that names another disk registry than stage 0 is refused" {
  sed -i 's|^SETEC_DISK_REPO=.*|SETEC_DISK_REPO=111122223333.dkr.ecr.us-east-1.amazonaws.com/other|' "$SUBSTRATE_AWS"
  PATH="$AWS_STUBS:$PATH" run env -u RESTORE_FROM STUB_ARCHIVE_OBJECTS=0 \
      "$REPO_ROOT/scripts/recreate-aws.sh" "$SUBSTRATE_AWS" staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"but stage 0 of staging made 111122223333.dkr.ecr.us-east-1.amazonaws.com/other"* ]]
}

@test "FAILING FIXTURE: a keyring from before D85, with no disk seed, is refused" {
  sed -i '/^SETEC_DISK_SIGNING_SEED=/d' "$KEYRING_AWS"
  PATH="$AWS_STUBS:$PATH" run env -u RESTORE_FROM STUB_ARCHIVE_OBJECTS=0 \
      "$REPO_ROOT/scripts/recreate-aws.sh" "$SUBSTRATE_AWS" staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"has no SETEC_DISK_SIGNING_SEED"* ]]
}

# A seed rotation (hosted#555): the overlay lists exactly the keys of the
# keyring seeds, the seed and the previous seed while one is kept.
OTHER_SEED="$(printf '%032d' 0 | base64 -w0)"

@test "a rotation in progress passes the disk gate when the overlay lists the new and the previous key" {
  sed -i "s|^SETEC_DISK_SIGNING_SEED=.*|SETEC_DISK_SIGNING_SEED=$OTHER_SEED|" "$KEYRING_AWS"
  printf 'SETEC_DISK_SIGNING_SEED_PREVIOUS=%s\n' "$DISK_SEED" >> "$KEYRING_AWS"
  new_key="$("$REPO_ROOT/scripts/keyring.sh" disk-public-key "$KEYRING_AWS")"
  sed -i "s|^\( *\)- \"$DISK_PUBLIC_KEY\"|\1- \"$new_key\"\n\1- \"$DISK_PUBLIC_KEY\"|" "$REPO_ROOT/$GITOPS_PATH/values.yaml"
  PATH="$AWS_STUBS:$PATH" run env -u RESTORE_FROM STUB_ARCHIVE_OBJECTS=0 \
      "$REPO_ROOT/scripts/recreate-aws.sh" "$SUBSTRATE_AWS" staging
  [[ "$output" == *"exactly the public keys of the keyring disk seeds"* ]]
}

@test "FAILING FIXTURE: a rotation in progress with no previous key in the overlay is refused" {
  sed -i "s|^SETEC_DISK_SIGNING_SEED=.*|SETEC_DISK_SIGNING_SEED=$OTHER_SEED|" "$KEYRING_AWS"
  printf 'SETEC_DISK_SIGNING_SEED_PREVIOUS=%s\n' "$DISK_SEED" >> "$KEYRING_AWS"
  new_key="$("$REPO_ROOT/scripts/keyring.sh" disk-public-key "$KEYRING_AWS")"
  sed -i "s|\"$DISK_PUBLIC_KEY\"|\"$new_key\"|" "$REPO_ROOT/$GITOPS_PATH/values.yaml"
  PATH="$AWS_STUBS:$PATH" run env -u RESTORE_FROM STUB_ARCHIVE_OBJECTS=0 \
      "$REPO_ROOT/scripts/recreate-aws.sh" "$SUBSTRATE_AWS" staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not list the key of SETEC_DISK_SIGNING_SEED_PREVIOUS"* ]]
  [[ "$output" == *"$DISK_PUBLIC_KEY"* ]]
}

@test "FAILING FIXTURE: an overlay that still lists the key of a retired seed is refused" {
  sed -i "s|^SETEC_DISK_SIGNING_SEED=.*|SETEC_DISK_SIGNING_SEED=$OTHER_SEED|" "$KEYRING_AWS"
  new_key="$("$REPO_ROOT/scripts/keyring.sh" disk-public-key "$KEYRING_AWS")"
  sed -i "s|^\( *\)- \"$DISK_PUBLIC_KEY\"|\1- \"$new_key\"\n\1- \"$DISK_PUBLIC_KEY\"|" "$REPO_ROOT/$GITOPS_PATH/values.yaml"
  PATH="$AWS_STUBS:$PATH" run env -u RESTORE_FROM STUB_ARCHIVE_OBJECTS=0 \
      "$REPO_ROOT/scripts/recreate-aws.sh" "$SUBSTRATE_AWS" staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"lists the setec disk public key $DISK_PUBLIC_KEY, which is the key of no seed"* ]]
}

# FAILING FIXTURE: an overlay with no serverName. Empty means CNPG's default,
# the Cluster's own name, which is right for a first bootstrap into an empty
# bucket and wrong for every later one. The gate must name the key.
@test "FAILING FIXTURE: an overlay that sets no backup.serverName is refused" {
  mkdir -p "$BATS_TEST_TMPDIR/no-servername"
  cat > "$BATS_TEST_TMPDIR/no-servername/values.yaml" <<YAML
platformPostgres:
  backup:
    destinationPath: "s3://\${bucket}/backups/postgres/"
    endpointURL: ""
gibson-workloads:
  setec:
    launcher:
      diskRepo: "$(grep -E '^SETEC_DISK_REPO=' "$SUBSTRATE_AWS" | cut -d= -f2-)"
      diskBuilder:
        publicKeys:
          - "$DISK_PUBLIC_KEY"
YAML
  cp "$REPO_ROOT/gitops/envs/staging/gibson-velero-values.yaml" "$BATS_TEST_TMPDIR/no-servername/"
  # GITOPS_PATH is the overlay the app-of-apps syncs, so the gate reads the
  # SAME file Argo renders from and the fixture travels the same way.
  PATH="$AWS_STUBS:$PATH" run env -u RESTORE_FROM \
      GITOPS_PATH="$(realpath --relative-to="$REPO_ROOT" "$BATS_TEST_TMPDIR/no-servername")" \
      "$REPO_ROOT/scripts/recreate-aws.sh" "$SUBSTRATE_AWS" staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"sets no platformPostgres.backup.serverName"* ]]
}

# The two AWS overlays carry a stamped name. Without this the gate above is
# the only thing standing between a re-bringup and a silent loss of backups,
# and it fires only once the archive is already used.
@test "both AWS overlays stamp a unique backup.serverName" {
  for env in staging prod; do
    run python3 -c '
import sys, yaml
v = yaml.safe_load(open(sys.argv[1])) or {}
b = ((v.get("platformPostgres") or {}).get("backup") or {})
name = str(b.get("serverName") or "")
assert name, "no serverName"
assert name != "platform-postgres", "the CNPG default is not a stamp"
print(name)
' "$REPO_ROOT/gitops/envs/$env/values.yaml"
    [ "$status" -eq 0 ]
  done
}

# hosted#425. The verb accepts one named overlay from a closed list, and no
# free values file. Each refusal fires before preflight, so no cluster is
# touched.
@test "FAILING FIXTURE: a free values file is refused by the kind recreate" {
  for var in EXTRA_VALUES VELERO_EXTRA_VALUES METRICS_SERVER_VALUES; do
    run env "$var=test/baseline/plugins.values.yaml" "$REPO_ROOT/scripts/recreate-kind.sh" "$SUBSTRATE_AWS"
    [ "$status" -eq 2 ]
    [[ "$output" == *"${var} is not accepted any more"* ]]
  done
}

# charts#503. Every kind cluster has the Mailpit sink, so the verb takes the
# developer rung when no rung is named, and it refuses the baseline alone.
@test "FAILING FIXTURE: the kind recreate refuses the baseline alone, which has no mail sink" {
  run env RUNG=baseline "$REPO_ROOT/scripts/recreate-kind.sh" "$SUBSTRATE_AWS"
  [ "$status" -eq 2 ]
  [[ "$output" == *"RUNG=baseline installs no mail sink"* ]]
  run env RUNG=nightly "$REPO_ROOT/scripts/recreate-kind.sh" "$SUBSTRATE_AWS"
  [ "$status" -eq 2 ]
  [[ "$output" == *"is not a kind rung"* ]]
}

# The default is read from behavior: with no RUNG, the script asks the chart
# source for the developer rung files. The chart source here has the umbrella
# directory and no rung file, and the tools are stubs, so it stops at that
# check, before any cluster.
@test "the kind recreate takes the developer rung when no rung is named" {
  mkdir -p "$BATS_TEST_TMPDIR/charts/helm/gibson" "$BATS_TEST_TMPDIR/bin"
  for t in kind kubectl helm terraform docker aws git curl; do
    printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/$t"
    chmod +x "$BATS_TEST_TMPDIR/bin/$t"
  done
  run env -u RUNG CHARTS_ROOT="$BATS_TEST_TMPDIR/charts" PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    "$REPO_ROOT/scripts/recreate-kind.sh" "$SUBSTRATE_AWS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no helm/gibson/values-developer.yaml, so RUNG=developer cannot be installed"* ]]
}

@test "an overlay that is not on the list is refused" {
  run env OVERLAY=test/signup/values.yaml "$REPO_ROOT/scripts/recreate-kind.sh" "$SUBSTRATE_AWS"
  [ "$status" -eq 2 ]
  [[ "$output" == *"is not on the list: plugins, signup, demo, identity"* ]]
}

@test "each named overlay maps to a file that exists" {
  count=0
  while IFS= read -r f; do
    [ -s "$REPO_ROOT/$f" ]
    count=$((count + 1))
  done < <(sed -n 's/^  [a-z]*) *EXTRA_VALUES="\(test\/[^"]*\)" ;;$/\1/p' "$REPO_ROOT/scripts/recreate-kind.sh")
  [ "$count" -eq 4 ]
}

@test "the Makefile passes OVERLAY to the verb and no free values file" {
  run grep -nE 'EXTRA_VALUES|METRICS_SERVER_VALUES' "$REPO_ROOT/Makefile"
  [ "$status" -eq 1 ]
  grep -q 'OVERLAY="$(OVERLAY)"' "$REPO_ROOT/Makefile"
  grep -q 'recreate ENV=kind OVERLAY=plugins' "$REPO_ROOT/Makefile"
}

# skopeo copy --all (hosted#602). An old skopeo stopped the staging recreate
# at the image copy on 2026-10-11, after preflight and the archive gate. Each
# cloud recreate must stop on it before any terraform call.
@test "FAILING FIXTURE: each cloud recreate refuses a skopeo with no copy --all before terraform" {
  cat > "$AWS_STUBS/skopeo" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "copy --help") printf '  --authfile string   path of the authentication file\n' ;;
  --version) echo "skopeo version 0.1.36-dev" ;;
  *) echo "skopeo must not copy" >&2; exit 99 ;;
esac
STUB
  printf '#!/usr/bin/env bash\necho "terraform $*" >> "%s/terraform.calls"\nexit 0\n' "$BATS_TEST_TMPDIR" > "$AWS_STUBS/terraform"
  chmod +x "$AWS_STUBS/skopeo" "$AWS_STUBS/terraform"
  for s in recreate-aws.sh recreate-ec2.sh; do
    PATH="$AWS_STUBS:$PATH" run env -u RESTORE_FROM STUB_ARCHIVE_OBJECTS=0 \
        "$REPO_ROOT/scripts/$s" "$SUBSTRATE_AWS" staging
    [ "$status" -ne 0 ] || { echo "$s: $output"; false; }
    [[ "$output" == *"has no copy --all"* ]] || { echo "$s: $output"; false; }
    [[ "$output" != *"must not copy"* ]]
    [ ! -s "$BATS_TEST_TMPDIR/terraform.calls" ] || { echo "$s called terraform:"; cat "$BATS_TEST_TMPDIR/terraform.calls"; false; }
  done
}

# A recreate that stopped in stage 2 leaves its cluster up, and the cluster
# archived into its directory. A second run continues the same cluster
# (hosted#624). The archive is that cluster's only when its oldest object is
# newer than the cluster.
@test "a run that continues the live cluster accepts the archive that cluster wrote" {
  for s in recreate-aws.sh recreate-ec2.sh; do
    PATH="$AWS_STUBS:$PATH" run env -u RESTORE_FROM STUB_ARCHIVE_OBJECTS=12 \
        STUB_LIVE_SINCE=2026-10-12T03:30:00+00:00 STUB_ARCHIVE_OLDEST=2026-10-12T03:36:10+00:00 \
        "$REPO_ROOT/scripts/$s" "$SUBSTRATE_AWS" staging
    [[ "$output" == *"was written by the live cluster"* ]] || { echo "$s: $output"; false; }
    [[ "$output" != *"already holds WAL from an earlier cluster"* ]]
  done
}

@test "FAILING FIXTURE: WAL older than the live cluster is an earlier cluster's, and is refused" {
  for s in recreate-aws.sh recreate-ec2.sh; do
    PATH="$AWS_STUBS:$PATH" run env -u RESTORE_FROM STUB_ARCHIVE_OBJECTS=12 \
        STUB_LIVE_SINCE=2026-10-12T03:30:00+00:00 STUB_ARCHIVE_OLDEST=2026-10-11T20:00:00Z \
        "$REPO_ROOT/scripts/$s" "$SUBSTRATE_AWS" staging
    [ "$status" -ne 0 ]
    [[ "$output" == *"already holds WAL from an earlier cluster"* ]] || { echo "$s: $output"; false; }
  done
}

@test "FAILING FIXTURE: WAL with no live cluster is refused" {
  for s in recreate-aws.sh recreate-ec2.sh; do
    PATH="$AWS_STUBS:$PATH" run env -u RESTORE_FROM -u STUB_LIVE_SINCE STUB_ARCHIVE_OBJECTS=12 \
        STUB_ARCHIVE_OLDEST=2026-10-12T03:36:10Z \
        "$REPO_ROOT/scripts/$s" "$SUBSTRATE_AWS" staging
    [ "$status" -ne 0 ]
    [[ "$output" == *"already holds WAL from an earlier cluster"* ]] || { echo "$s: $output"; false; }
  done
}
