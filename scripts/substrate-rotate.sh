#!/usr/bin/env bash
# substrate-rotate.sh — rotate the access key of one substrate IAM user with
# no outage (ADR-0171, row substrate-cloud-credentials).
#
# Stage 0 keeps two access key slots on each IAM user (key_slots in
# substrate/gibson-bootstrap/variables.tf, the state file
# <state-dir>/key-slots.tfvars.json). One rotation, run at stage 0 on the
# runner of a workflow (ADR-0083, amendment of 2026-10-21):
# .github/workflows/rotate-credentials.yml for staging and prod, and
# .github/workflows/drill.yml for drill. The role of the first workflow can
# change only the access keys of these users (substrate/gibson-bootstrap/
# rotation-role.tf). The call is:
#
#   1. Add the free slot and make it active: terraform applies a new key and
#      deletes nothing. The outputs now give the new key.
#   2. Write the new key into the keyring (keyring.sh set), and rewrite
#      substrate.env (substrate.sh).
#   3. Push the keyring to the cluster (keyring-to-cluster.sh), restart
#      each Deployment, StatefulSet and DaemonSet whose pods read the Secret
#      keys of this user, and wait until each runs again. OpenBao is not
#      restarted: it reads its inputs from a mounted volume each pass.
#      smtp has one more hop: the OpenBao input pass writes the keyring
#      value to ses-smtp-credentials, and ESO writes the Secret that the
#      PlatformBootstrap names (spec.zitadel.smtp.passwordSecretRef). The
#      script waits for that Secret, restarts its readers, and makes the
#      platform-operator apply the new password to the Zitadel SMTP
#      provider: status.smtpSettingsHash differs from the hash that step 1
#      recorded, with SMTPProviderReady True.
#   4. platform, dns, setec-disk-builder: wait until AWS reports the new key in use
#      (iam get-access-key-last-used). smtp: the platform sends mail only now
#      and then, so the relay must accept the new credential at once (SMTP
#      AUTH, no mail sent).
#   5. Wait until the old key has not been used for QUIET_SECS after the
#      switch. A consumer that still uses it keeps it alive: the script stops
#      and names the key, and a later run continues from here.
#   6. Drop the old slot: terraform deletes exactly that one access key, and
#      AWS refuses the old key from then on.
#
# A second run of a rotation that stopped continues at the step it reached:
# two slots in the state file mean "rotation in progress".
#
# Usage: substrate-rotate.sh <state-dir> <env> <platform|smtp|dns|setec-disk-builder>
# Env:   WAIT_SECS  (default 21600) the wait for the new key to be used
#        SECRET_WAIT_SECS (default WAIT_SECS) the wait of an smtp rotation for
#                   the derived Secret, which follows the OpenBao input pass
#        QUIET_SECS (default 14400) the time the old key must stay unused
#                   after the switch. AWS updates the last-used time with a
#                   delay, so this is longer than that delay.
#        NS         the release namespace (default gibson)
# Exit:  0 rotated · 10 stopped, run again later · 2 could not run (also a
#          failed command, terraform included)
#        3 halted: a person must act first (the relay refuses the new SMTP
#          key, or a consumer used the old key after the switch)
#        Only exit 10 is a wait. Any other code but 0 is a failure.
set -euo pipefail

STATE="${1:-}"; ENV="${2:-}"; USER_NAME="${3:-}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/keyring-pushed.sh
. "$REPO/scripts/lib/keyring-pushed.sh"
TF_DIR="$REPO/substrate/gibson-bootstrap"
KEYRING="$REPO/scripts/keyring.sh"
# Overridable for tests/harness/substrate-rotate.bats only.
SUBSTRATE_SH="${SUBSTRATE_SH:-$TF_DIR/substrate.sh}"
K2C="${K2C:-$REPO/scripts/keyring-to-cluster.sh}"
SLEEP_SECS="${SLEEP_SECS:-300}"
WAIT_SECS="${WAIT_SECS:-21600}"
SECRET_WAIT_SECS="${SECRET_WAIT_SECS:-$WAIT_SECS}"
QUIET_SECS="${QUIET_SECS:-14400}"
NS="${NS:-gibson}"
# The wait has its own exit code. 1 is the code of too many failures (a shell,
# terraform, scripts/with-cluster.sh before it), so a wait that returned 1 could
# not be told from a run that did nothing (drill rotation run 1, review of
# hosted#66). Only stop returns it.
EXIT_WAIT=10
die()  { printf '! [substrate-rotate] %s\n' "$*" >&2; exit 2; }
stop() { printf '! [substrate-rotate] %s\n' "$*" >&2; exit "$EXIT_WAIT"; }
# halt: the rotation cannot go on until a person acts. A later run that
# changes nothing stops here again, so it is not a wait.
halt() { printf '! [substrate-rotate] %s\n' "$*" >&2; exit 3; }
say()  { printf '  ✓ [substrate-rotate] %s\n' "$*"; }

[ -n "$STATE" ] && [ -n "$ENV" ] && [ -n "$USER_NAME" ] || die "usage: substrate-rotate.sh <state-dir> <env> <platform|smtp|dns|setec-disk-builder>"
case "$ENV" in staging|prod|drill) ;; *) die "ENV=$ENV has no AWS stage 0" ;; esac
# The stage 0 files live in the durable bucket (scripts/stage0-store.sh). The
# run reads them first, and keeps every change in AWS when it ends, stopped
# or done.
# shellcheck source=stage0-store.sh
. "$REPO/scripts/stage0-store.sh"
stage0_pull "$ENV" "$STATE"
trap 'stage0_push "$ENV" "$STATE"' EXIT
SLOTS="$STATE/key-slots.tfvars.json"
# The time of the last switch of each user. Not a Terraform variable.
SWITCHED="$STATE/key-rotation.json"
VARFILE="envs/$ENV.tfvars"
[ -s "$SLOTS" ] || die "$SLOTS is missing: run make substrate ENV=$ENV first"
for tool in terraform aws jq kubectl python3 openssl; do command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"; done

# THE ROOT IS INITIALIZED BEFORE ANY terraform CALL. A runner is fresh, and a
# rotation that is already open goes straight to `terraform output` with no
# apply before it. Without an init that call stops with "Backend
# initialization required" (drill rotation run 1, each of platform, smtp and
# dns). stage0_init reads the backend of the env: S3 for drill, the local
# state file otherwise.
stage0_init "$TF_DIR" "$ENV" "$STATE"

# A command that fails without a decision of this script is "could not run"
# (exit 2), never "stopped, run again later" (exit 10). set -e would pass the
# exit code of the command on, and terraform exits 1 on an error, so a failed
# terraform call read as a wait and the drill step stayed green. Only stop
# exits 10 (drill rotation run 1, hosted#59 thread).
set -E
trap 'exit 2' ERR

# The keyring members and the cluster Secret keys of each user.
case "$USER_NAME" in
  platform) MEMBERS="BUCKET_ACCESS_KEY:platform_access_key_id BUCKET_SECRET_KEY:platform_secret_access_key"
            SECRET_KEYS="$NS/bringup-keyring/bucket-access-key $NS/bringup-keyring/bucket-secret-key velero/velero-bucket-credential/cloud" ;;
  smtp)     MEMBERS="SMTP_PASSWORD:smtp_password"
            # Only OpenBao reads bringup-keyring/smtp-*; the readers are
            # those of the derived Secret (step 3, smtp).
            SECRET_KEYS="" ;;
  dns)      MEMBERS="DNS_ACCESS_KEY:dns_access_key_id DNS_SECRET_KEY:dns_secret_access_key"
            SECRET_KEYS="$NS/route53-credential/access-key-id $NS/route53-credential/secret-access-key" ;;
  # The disk builder push pair (D85). Its reader in the cluster is the
  # registry Secret of the disk builder that the chart renders from it.
  setec-disk-builder)
            MEMBERS="SETEC_DISK_PUSH_ACCESS_KEY:setec_disk_builder_access_key_id SETEC_DISK_PUSH_SECRET_KEY:setec_disk_builder_secret_access_key"
            SECRET_KEYS="$NS/setec-disk-push-credential/access-key-id $NS/setec-disk-push-credential/secret-access-key" ;;
  *) die "CREDENTIAL=$USER_NAME is not one of platform, smtp, dns, setec-disk-builder" ;;
esac

tf() { terraform -chdir="$TF_DIR" "$@"; }
slots_get() { jq -r --arg u "$USER_NAME" "$1" "$SLOTS"; }
slots_put() {  # $1 active, $2.. keep
  local active="$1"; shift
  local tmp; tmp="$(mktemp "$STATE/.key-slots.XXXXXX")"
  jq --arg u "$USER_NAME" --arg a "$active" --args '.key_slots[$u] = {active: $a, keep: $ARGS.positional}' "$@" < "$SLOTS" > "$tmp"
  chmod 0600 "$tmp"; mv "$tmp" "$SLOTS"
}
# apply ALLOWED_DELETE: plan and apply; refuse any delete other than ALLOWED_DELETE.
apply() {
  local work; work="$(mktemp -d)"
  tf plan -input=false -no-color -var-file="$VARFILE" -var-file="$SLOTS" -out="$work/plan.out" >/dev/null
  tf show -json "$work/plan.out" > "$work/plan.json"
  local deletes
  deletes="$(jq -r '[.resource_changes[] | select(.change.actions | index("delete")) | .address] | join(" ")' "$work/plan.json")"
  [ "$deletes" = "${1:-}" ] || { rm -rf "$work"; die "the plan deletes '${deletes}', and this step allows '${1:-nothing}'"; }
  tf apply -input=false -no-color "$work/plan.out" >/dev/null
  rm -rf "$work"
}
key_id() { tf output -json access_key_ids | jq -r --arg u "$USER_NAME" --arg s "$1" '.[$u][$s] // empty'; }
last_used() {  # $1 key id: the epoch of its last use, or 0
  local d
  d="$(aws iam get-access-key-last-used --access-key-id "$1" --query 'AccessKeyLastUsed.LastUsedDate' --output text 2>/dev/null || true)"
  case "$d" in ''|None) echo 0 ;; *) date -d "$d" +%s ;; esac
}

active="$(slots_get '.key_slots[$u].active')"
nkeep="$(slots_get '.key_slots[$u].keep | length')"
if [ "$nkeep" = 1 ]; then
  # 1. Add the free slot and make it active.
  old="$active"; new="$([ "$old" = a ] && echo b || echo a)"
  [ -s "$SWITCHED" ] || echo '{}' > "$SWITCHED"
  # smtp: the status hash of the Zitadel SMTP provider before the switch. It
  # covers the password (Argon2id, gibson smtpSettingsHash), so a new hash
  # later means the platform-operator applied a new password.
  hash_before=""
  [ "$USER_NAME" != smtp ] || hash_before="$(kubectl get platformbootstrap -o json | jq -r '.items[0].status.smtpSettingsHash // ""')"
  # A new rotation has no switch time yet. Step 3c records it when the
  # cluster holds the new key and each reader restarted onto it. The time of
  # the last rotation goes BEFORE the slots change: a run that stops after
  # the slots change continues as an open rotation, and a kept old time
  # would read every use of the old key as a consumer that still holds it.
  jq --arg u "$USER_NAME" --arg h "$hash_before" \
    'del(.[$u]) | del(.halted[$u]?) | if $u == "smtp" then .smtp_settings_hash_before = $h else . end' "$SWITCHED" > "$SWITCHED.tmp" && mv "$SWITCHED.tmp" "$SWITCHED"
  slots_put "$new" "$old" "$new"
  apply ""
  say "slot $new of $USER_NAME holds a new key $(key_id "$new"); slot $old keeps the old key"
else
  new="$active"; old="$([ "$new" = a ] && echo b || echo a)"
  say "a rotation of $USER_NAME is in progress: slot $new is active, slot $old keeps the old key"
fi
new_id="$(key_id "$new")"; old_id="$(key_id "$old")"
[ -n "$new_id" ] && [ -n "$old_id" ] || die "the state holds no key in slot $new or $old of $USER_NAME"

# 2. The keyring and substrate.env.
for m in $MEMBERS; do
  name="${m%%:*}"; value="$(tf output -raw "${m#*:}")"
  [ "$("$KEYRING" get "$STATE/keyring.env" "$name")" = "$value" ] || "$KEYRING" set "$STATE/keyring.env" "$name" "$value" >/dev/null
done
value=""
"$SUBSTRATE_SH" "$STATE" "$ENV" >/dev/null
say "the keyring and substrate.env hold the new key"

# readers NS SECRET KEY: each Deployment, StatefulSet and DaemonSet whose pods
# read the key, as kind/name. OpenBao is left out: it reads its inputs from a
# mounted volume each pass, and the kubelet updates that volume in place.
readers() {
  kubectl -n "$1" get deploy,statefulset,daemonset -o json | jq -r --arg s "$2" --arg k "$3" '
    .items[] | select(
      ([.spec.template.spec | (.containers + (.initContainers // []))[] |
        (.env // [])[] | .valueFrom.secretKeyRef? | select(. != null and .name == $s and .key == $k)] | length > 0)
      or ([.spec.template.spec.volumes[]? | .secret? | select(. != null and .secretName == $s)
            | select((.items // null) == null or ([.items[].key] | index($k)))] | length > 0))
    | "\(.kind | ascii_downcase)/\(.metadata.name)"
    | select(test("^statefulset/.*openbao$") | not)' | sort -u
}
# restart NS WORKLOAD...: restart each by deleting its pods one at a time
# (scripts/lib/restart-pods.sh: the identity admission policy denies a
# `rollout restart` of a platform workload), and wait until each runs again.
# shellcheck source=lib/restart-pods.sh
. "$REPO/scripts/lib/restart-pods.sh"
restart() {
  local ns="$1" w; shift
  for w in "$@"; do
    restart_pods "$ns" "$w" "${RESTART_TIMEOUT:-600}" \
      || stop "$ns/$w does not run again after the restart; the old key stays. Run again after it does"
    if [ "$RESTART_PODS_RESULT" = nothing ]; then
      say "nothing to restart in $ns/$w: it wants 0 pods, so no pod read the key"
    else
      say "restarted $ns/$w"
    fi
  done
}
secret_value() { kubectl -n "$1" get secret "$2" -o json 2>/dev/null | jq -r --arg k "$3" '.data[$k] // empty' | base64 -d; }

# 3. The cluster: the producer of the keyring Secrets, and a restart of each
#    workload whose pods read one of the Secret keys of this user.
# From here the cluster may hold the new key. The marker tells the workflow to
# write the keyring back on any exit (scripts/lib/keyring-pushed.sh).
: > "$STATE/$PUSHED_MARKER"
"$K2C" "$STATE/substrate.env" >/dev/null
for sk in $SECRET_KEYS; do
  ns="${sk%%/*}"; rest="${sk#*/}"; sec="${rest%%/*}"; key="${rest#*/}"
  mapfile -t ws < <(readers "$ns" "$sec" "$key")
  [ "${#ws[@]}" -eq 0 ] || restart "$ns" "${ws[@]}"
done

# 3a. CNPG Postgres reads the bucket key through its Cluster, and no
#     Deployment, StatefulSet or DaemonSet owns its pods, so readers() finds
#     none. Its instance manager caches the archive credentials and reads them
#     again only on a reconcile of the Cluster (CNPG 1.30,
#     internal/management/controller/cache.go). A changed Secret starts none:
#     drill rotation run 40402546442 found the old platform key in use 38
#     minutes after the switch. `kubectl cnpg reload` sets the annotation
#     cnpg.io/reloadedAt, and each instance reconciles at once. CNPG records
#     no "reloaded" marker, so the switch time below comes CNPG_RELOAD_SECS
#     after the annotation. No Postgres restarts (ADR-0171: no step stops the
#     service).
reloaded=0
for sk in $SECRET_KEYS; do
  ns="${sk%%/*}"; rest="${sk#*/}"; sec="${rest%%/*}"
  clusters_json="$(kubectl -n "$ns" get clusters.postgresql.cnpg.io -o json)" \
    || die "cannot list the CNPG Clusters of $ns (the error is above), so a Postgres could keep the old key"
  # The backup store and each restore source (externalClusters) of a Cluster
  # can name the Secret. Both caches refresh on the same reconcile.
  # The guard check-secrets-off-argv refuses jq --arg in this script, so the
  # Secret name goes in through the environment.
  mapfile -t cs < <(CNPG_SECRET="$sec" jq -r 'env.CNPG_SECRET as $s | .items[]
      | select([(.spec.backup.barmanObjectStore.s3Credentials // empty),
                (.spec.externalClusters[]?.barmanObjectStore.s3Credentials // empty)]
               | any(.accessKeyId.name == $s or .secretAccessKey.name == $s))
      | .metadata.name' <<<"$clusters_json" | sort -u)
  for c in "${cs[@]}"; do
    kubectl -n "$ns" annotate clusters.postgresql.cnpg.io "$c" "cnpg.io/reloadedAt=$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite >/dev/null \
      || die "could not reload the CNPG Cluster $ns/$c, so it keeps the old key"
    say "reloaded the CNPG Cluster $ns/$c, which archives with $sec"
    reloaded=1
  done
done
[ "$reloaded" -eq 0 ] || sleep "${CNPG_RELOAD_SECS:-30}"

if [ "$USER_NAME" = smtp ]; then
  # 3b. The Secret that the PlatformBootstrap names, then its readers, then
  #     the Zitadel SMTP provider.
  pb="$(kubectl get platformbootstrap -o json | jq -c '.items[0] // empty')"
  [ -n "$pb" ] || die "the cluster has no PlatformBootstrap"
  pb_name="$(jq -r .metadata.name <<<"$pb")"
  smtp="$(jq -c '.spec.zitadel.smtp // empty' <<<"$pb")"
  [ -n "$smtp" ] || die "the PlatformBootstrap sets no spec.zitadel.smtp: this install sends no mail"
  ref() { jq -r --arg d "$NS" "$1 | \"\(.namespace // \$d) \(.name) \(.key)\"" <<<"$smtp"; }
  read -r pns psec pkey < <(ref .passwordSecretRef)
  read -r uns usec ukey < <(ref .userSecretRef)
  new_pw="$(tf output -raw smtp_password)"; new_user="$(tf output -raw smtp_user)"
  # The new value reaches OpenBao on the next input pass (every 5 minutes),
  # after the kubelet updates the mounted keyring (up to about a minute).
  # SECRET_WAIT_SECS bounds this wait. It is apart from WAIT_SECS, which a
  # drill run keeps short (review of hosted#749).
  deadline=$(( $(date +%s) + SECRET_WAIT_SECS ))
  while :; do
    # The input pass runs every five minutes; then ESO refreshes at once.
    kubectl -n "$pns" annotate externalsecret "$psec" "force-sync=$(date +%s)" --overwrite >/dev/null 2>&1 || true
    [ "$(secret_value "$pns" "$psec" "$pkey")" = "$new_pw" ] && [ "$(secret_value "$uns" "$usec" "$ukey")" = "$new_user" ] && break
    [ "$(date +%s)" -lt "$deadline" ] || stop "$pns/$psec does not hold the new SMTP credential yet; run again to continue"
    sleep "$SLEEP_SECS"
  done
  say "$pns/$psec holds the new SMTP credential"
  # The copies of that Secret in other namespaces, for example the
  # Alertmanager configuration of drill (monitoring/alertmanager-config,
  # refreshInterval 1h). Each one refreshes now, before the readers restart,
  # so the restart time also covers the reload of a copy, and no copy sends
  # mail with the old key after the switch time of step 3c. A copy reads the
  # Secret through spec.data or spec.dataFrom[].extract. A copy through
  # dataFrom[].find or a generator is not found: none exists today.
  copies_since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  all_es="$(kubectl get externalsecrets -A -o json)" \
    || die "cannot list the ExternalSecrets of the cluster (the error is above), so a copy of $pns/$psec could keep the old key"
  mapfile -t copies < <(jq -r --arg k "$psec" --arg ns "$pns" '
    .items[] | select(.metadata.namespace != $ns)
    | select(([.spec.data[]?.remoteRef.key] + [.spec.dataFrom[]?.extract.key]) | index($k))
    | "\(.metadata.namespace) \(.metadata.name)"' <<<"$all_es")
  for c in "${copies[@]}"; do
    read -r cns cname <<<"$c"
    kubectl -n "$cns" annotate externalsecret "$cname" "force-sync=$(date +%s)" --overwrite >/dev/null
  done
  deadline=$(( $(date +%s) + WAIT_SECS ))
  for c in "${copies[@]}"; do
    read -r cns cname <<<"$c"
    until kubectl -n "$cns" get externalsecret "$cname" -o json | jq -e --arg t "$copies_since" '
            (.status.refreshTime // "") >= $t
            and ([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length) > 0' >/dev/null; do
      [ "$(date +%s)" -lt "$deadline" ] || stop "the copy $cns/$cname of $pns/$psec has not refreshed yet; run again to continue"
      sleep "$SLEEP_SECS"
    done
    say "the copy $cns/$cname refreshed from $pns/$psec"
  done
  mapfile -t ws < <({ readers "$pns" "$psec" "$pkey"; readers "$uns" "$usec" "$ukey"; } | sort -u)
  [ "${#ws[@]}" -eq 0 ] || restart "$pns" "${ws[@]}"
  # The platform-operator applies the password on a reconcile; an annotation
  # starts one. Its status hash covers the password, and the spec does not
  # change, so a hash other than the one before the switch is the new password.
  before="$(jq -r '.smtp_settings_hash_before // ""' "$SWITCHED")"
  [ -n "$before" ] || die "$SWITCHED records no SMTP settings hash from before the switch"
  kubectl annotate platformbootstrap "$pb_name" "gibson.zeroroot.ai/smtp-rotated=$(date +%s)" --overwrite >/dev/null
  # Its own deadline: the wait for the Secret above may have used the first.
  deadline=$(( $(date +%s) + WAIT_SECS ))
  until now_hash="$(kubectl get platformbootstrap "$pb_name" -o json | jq -r '
           if ([.status.conditions[]? | select(.type == "SMTPProviderReady" and .status == "True")] | length) > 0
           then .status.smtpSettingsHash // "" else "" end')" && [ -n "$now_hash" ] && [ "$now_hash" != "$before" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || stop "the Zitadel SMTP provider does not hold the new password yet; the old key stays. Run again to continue"
    sleep "$SLEEP_SECS"
  done
  say "the platform-operator applied the new SMTP password to Zitadel"
fi

# 3c. The switch time. It is the moment the cluster holds the new key and
#     each reader of it runs again. Before that moment a reader still on its
#     old pod may use the old key, and that use is not a consumer that holds
#     the old key. A switch time taken at the apply of step 1 read each such
#     use as a consumer, and step 5 halted (review of hosted#749). A later
#     run of the same rotation keeps the first time.
[ -s "$SWITCHED" ] || echo '{}' > "$SWITCHED"
# The readers of this run restarted onto the new key before this time.
restarted="$(date +%s)"
switched="$(jq -r --arg u "$USER_NAME" '.[$u] // 0' "$SWITCHED" 2>/dev/null || echo 0)"
if [ "$switched" -le 0 ]; then
  switched="$(date +%s)"
  jq --arg u "$USER_NAME" --argjson t "$switched" '.[$u] = $t' "$SWITCHED" > "$SWITCHED.tmp" && mv "$SWITCHED.tmp" "$SWITCHED"
  say "the cluster runs on the new key of $USER_NAME from $(date -u -d "@$switched" +%FT%TZ)"
fi

# 4. The new key works.
if [ "$USER_NAME" = smtp ]; then
  host="$(jq -r .host <<<"$smtp")"; port="$(jq -r .port <<<"$smtp")"
  auth="$(printf '\0%s\0%s' "$new_user" "$new_pw" | base64 -w0)"
  { sleep 3; printf 'EHLO substrate-rotate\r\n'; sleep 2; printf 'AUTH PLAIN %s\r\n' "$auth"; sleep 3; printf 'QUIT\r\n'; } \
    | timeout 60 openssl s_client -quiet -starttls smtp -connect "$host:$port" 2>/dev/null | grep -q '^235' \
    || halt "the relay $host:$port refuses the new SMTP credential; the old key stays"
  auth=""; new_pw=""
  say "the relay $host:$port accepts the new SMTP credential"
else
  deadline=$(( $(date +%s) + WAIT_SECS ))
  until [ "$(last_used "$new_id")" -gt 0 ]; do
    [ "$(date +%s)" -lt "$deadline" ] || stop "AWS reports no use of the new key $new_id yet; run again to continue"
    sleep "$SLEEP_SECS"
  done
  say "AWS reports the new key $new_id in use"
fi

# 5. The old key stays unused for QUIET_SECS after the switch.
#    A use after the switch halts the run, and the halt records the time of
#    that use. The next run is the action of the person who fixed the
#    consumer. When the last use is still the recorded one, and it comes
#    before the restarts of this run, no consumer used the old key since the
#    halt. The switch then moves to the restarts of this run, and the quiet
#    time starts again. A use after the recorded one halts again. AWS keeps
#    only the time of the last use, so without this a halt could never clear
#    (drill run 40418009633).
olu="$(last_used "$old_id")"
if [ "$olu" -ge "$switched" ]; then
  halted="$(jq -r --arg u "$USER_NAME" '.halted[$u] // 0' "$SWITCHED")"
  if [ "$olu" -eq "$halted" ] && [ "$olu" -lt "$restarted" ]; then
    switched="$restarted"
    jq --arg u "$USER_NAME" --argjson t "$switched" '.[$u] = $t | del(.halted[$u])' "$SWITCHED" > "$SWITCHED.tmp" && mv "$SWITCHED.tmp" "$SWITCHED"
    say "the old key $old_id has no use since the halt at its use of $(date -u -d "@$olu" +%FT%TZ); the switch moves to $(date -u -d "@$switched" +%FT%TZ)"
  else
    jq --arg u "$USER_NAME" --argjson t "$olu" '.halted[$u] = $t' "$SWITCHED" > "$SWITCHED.tmp" && mv "$SWITCHED.tmp" "$SWITCHED"
    halt "the old key $old_id was used at $(date -u -d "@$olu" +%FT%TZ), after the switch: a consumer still holds it. Find it, restart it, and run again"
  fi
fi
[ $(( $(date +%s) - switched )) -ge "$QUIET_SECS" ] \
  || stop "the switch was $(( ($(date +%s) - switched) / 60 )) minutes ago; the old key must stay unused for $(( QUIET_SECS / 60 )). Run again later"
say "the old key $old_id has not been used since the switch"

# 6. Drop the old slot. AWS refuses the old key from now on.
slots_put "$new" "$new"
case "$USER_NAME" in
  platform) addr="aws_iam_access_key.platform[\"$old\"]" ;;
  smtp)     addr="aws_iam_access_key.smtp[\"$old\"]" ;;
  dns)      addr="aws_iam_access_key.dns[\"$old\"]" ;;
  setec-disk-builder) addr="aws_iam_access_key.setec_disk_builder[\"$old\"]" ;;
esac
apply "$addr"
"$SUBSTRATE_SH" "$STATE" "$ENV" >/dev/null
say "deleted the old key $old_id of $USER_NAME; the rotation is done. Update the GitHub Environment secret of the keyring"
