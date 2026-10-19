# shellcheck shell=bash
# ---------------------------------------------------------------------------
# restore-recovery.sh — the Postgres recovery values of a restore on an EC2 or
# EKS env, and the PR that brings Git back to the truth after it (D91).
#
# A restore needs three values that exist only at run time. The verb derives
# all three from the named backup (ADR-0083), and never takes one from a
# person:
#
#   platformPostgres.recovery.backupID    the base backup id in the backup record
#   platformPostgres.recovery.serverName  the archive that base backup lives in
#   platformPostgres.backup.serverName    the NEW archive, restore_archive_name
#
# They go on the gibson Application as Helm parameters, before the
# app-of-apps exists. The app-of-apps ignores exactly that one path of that
# one Application (bootstrap/modules/argocd, RespectIgnoreDifferences), and
# scripts/check-app-of-apps-ignore.py fails any other ignored path. So the
# app-of-apps adopts the Application and keeps the parameters.
#
# Git catches up by a PR. It writes the new archive name into the env overlay.
# After it merges, `make restore-settle ENV=<env>` removes the parameters from
# the live Application, and Git is the truth again. A throwaway env (the
# drill) skips the PR, and checks the content it would have written instead.
#
# The caller supplies REPO, WORK, ENV_NAME, GITOPS_PATH, RESTORE_FROM,
# RECOVERY_BACKUP_ID, RECOVERY_ARCHIVE_NAME, RESTORE_ARCHIVE_NAME, log, die.
# ---------------------------------------------------------------------------

# The only parameter names the verb may set, in this order. The guard reads
# this line.
RECOVERY_PARAMETERS="platformPostgres.recovery.backupID platformPostgres.recovery.serverName platformPostgres.backup.serverName"

# The envs that are destroyed after each run, so Git never has to learn their
# restore archive (ADR-0095). One list, shared with scripts/reap-throwaway.sh.
# shellcheck source=lib/throwaway-envs.sh
. "$HERE/lib/throwaway-envs.sh"

# recovery_values — the three values, one per line, in RECOVERY_PARAMETERS
# order.
recovery_values() {
  printf '%s\n%s\n%s\n' "$RECOVERY_BACKUP_ID" "$RECOVERY_ARCHIVE_NAME" "$RESTORE_ARCHIVE_NAME"
}

# gibson_app_with_recovery — the gibson Application of the overlay, with the
# three parameters on its chart source, on stdout.
gibson_app_with_recovery() {
  # shellcheck disable=SC2086  # the names are one word each, on purpose
  RECOVERY_VALUES="$(recovery_values)" python3 - "$REPO/${GITOPS_PATH}/gibson.yaml" $RECOVERY_PARAMETERS <<'PY'
import os, sys, yaml
path, names = sys.argv[1], sys.argv[2:]
values = os.environ["RECOVERY_VALUES"].split("\n")
app = yaml.safe_load(open(path))
if (app.get("kind"), (app.get("metadata") or {}).get("name")) != ("Application", "gibson"):
    sys.exit("%s is not the Application gibson" % path)
src = ((app.get("spec") or {}).get("sources") or [None])[0] or {}
if src.get("chart") != "gibson":
    sys.exit("%s: sources[0] is not the gibson chart, so /spec/sources/0/helm/parameters, the one path "
             "the app-of-apps ignores, would name another source" % path)
helm = src.setdefault("helm", {})
if helm.get("parameters"):
    sys.exit("%s already sets helm.parameters on the gibson chart. Those are the restore's own seam (D91)" % path)
if len(values) != len(names) or not all(values):
    sys.exit("a recovery value is empty: %r" % dict(zip(names, values)))
helm["parameters"] = [{"name": n, "value": v} for n, v in zip(names, values)]
yaml.safe_dump(app, sys.stdout, sort_keys=False)
PY
}

# apply_gibson_with_recovery — create the gibson Application with the three
# parameters. It runs after the secret store is home and before the
# app-of-apps exists, so no sync of the gibson chart ever runs without them.
apply_gibson_with_recovery() {
  local app="$WORK/gibson-with-recovery.yaml"
  gibson_app_with_recovery > "$app" \
    || die "could not build the gibson Application with the recovery values (see the line above)"
  kubectl apply -f "$app" >/dev/null \
    || die "could not create the gibson Application with the recovery values"
  printf '  ✓ Application gibson created with recovery from %s (base backup %s), archiving to %s\n' \
    "$RECOVERY_ARCHIVE_NAME" "$RECOVERY_BACKUP_ID" "$RESTORE_ARCHIVE_NAME"
}

# overlay_with_archive <values.yaml> <name> — the overlay with
# platformPostgres.backup.serverName set to <name>, on stdout. One line
# changes, and comments stay.
overlay_with_archive() {
  python3 "$HERE/lib/overlay-server-name.py" "$1" "$2"
}

# restore_catch_up_body — the body of the catch-up PR.
restore_catch_up_body() {
  cat <<EOF
## What

Env \`${ENV_NAME}\` was restored from backup \`${RESTORE_FROM}\` (D91). Its Postgres now archives to a new directory. This PR writes that name into \`${GITOPS_PATH}/values.yaml\`, so that Git names the archive the live cluster writes.

| Value | Live parameter on Application gibson |
|---|---|
| \`platformPostgres.backup.serverName\` | \`${RESTORE_ARCHIVE_NAME}\` (this PR writes it to Git) |
| \`platformPostgres.recovery.backupID\` | \`${RECOVERY_BACKUP_ID}\` (not in Git: used once, at bootstrap) |
| \`platformPostgres.recovery.serverName\` | \`${RECOVERY_ARCHIVE_NAME}\` (not in Git: used once, at bootstrap) |

## After this merges

Run \`make restore-settle ENV=${ENV_NAME}\`. It checks that the overlay names \`${RESTORE_ARCHIVE_NAME}\`, then removes the three parameters from the live Application. Git is then the truth again.

The source archive \`${RECOVERY_ARCHIVE_NAME}\` stays. It is the restore source for the cluster that wrote it (ADR-0083).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
}

# restore_catch_up — the bundle for the catch-up PR, and the PR itself unless
# RESTORE_CATCH_UP_PR=later.
#
# The bundle goes to RESTORE_CATCH_UP_DIR (default: under WORK). A workflow
# sets RESTORE_CATCH_UP_PR=later and a directory it uploads, so that a small
# job with the write token opens the PR (scripts/restore-catch-up.sh,
# hosted#687) and the recreate job, which holds the bringup role, keeps a
# read token. A workstation run opens the PR at once with the operator's own
# credential. A throwaway env writes the bundle and opens nothing.
restore_catch_up() {
  local overlay="$REPO/${GITOPS_PATH}/values.yaml" dir="${RESTORE_CATCH_UP_DIR:-$WORK/catch-up-bundle}" got url
  mkdir -p "$dir" || die "could not make the catch-up bundle directory ${dir}"
  overlay_with_archive "$overlay" "$RESTORE_ARCHIVE_NAME" > "$dir/values.yaml" \
    || die "could not write ${RESTORE_ARCHIVE_NAME} into a copy of ${overlay}"
  got="$(python3 -c '
import sys, yaml
v = yaml.safe_load(open(sys.argv[1])) or {}
print(((v.get("platformPostgres") or {}).get("backup") or {}).get("serverName") or "")' "$dir/values.yaml")"
  [ "$got" = "$RESTORE_ARCHIVE_NAME" ] \
    || die "the catch-up overlay names serverName '${got}', not ${RESTORE_ARCHIVE_NAME}"
  restore_catch_up_body > "$dir/body.md"
  cat > "$dir/meta.env" <<EOF
ENV_NAME=${ENV_NAME}
RESTORE_FROM=${RESTORE_FROM}
GITOPS_PATH=${GITOPS_PATH}
RESTORE_ARCHIVE_NAME=${RESTORE_ARCHIVE_NAME}
BRANCH=restore/${ENV_NAME}-${RESTORE_FROM}
TITLE=fix(${ENV_NAME}): the overlay names the archive of the restore from ${RESTORE_FROM}
EOF

  case " $THROWAWAY_ENVS " in
    *" $ENV_NAME "*)
      printf '  ✓ %s is a throwaway env: no catch-up PR. The overlay it would write names %s (bundle in %s)\n' "$ENV_NAME" "$RESTORE_ARCHIVE_NAME" "$dir"
      # shellcheck disable=SC2034  # printed by lib/bringup-after-cluster.sh
      RESTORE_GIT_STATUS="restored, throwaway env: Git is not updated"
      return 0 ;;
  esac

  if [ "${RESTORE_CATCH_UP_PR:-now}" = later ]; then
    printf '  ✓ the catch-up bundle is in %s; the catch-up job opens the PR\n' "$dir"
    # shellcheck disable=SC2034  # printed by lib/bringup-after-cluster.sh
    RESTORE_GIT_STATUS="restored, Git catching up: the catch-up job opens the PR from ${dir}"
    return 0
  fi
  url="$("$HERE/restore-catch-up.sh" "$dir" | tee /dev/stderr | sed -n 's/^CATCH_UP_PR=//p' | tail -1)"
  [ -n "$url" ] \
    || die "the restore is healthy, and the catch-up PR did not open (see above). The bundle is in ${dir}: run scripts/restore-catch-up.sh ${dir}"
  # shellcheck disable=SC2034  # printed by lib/bringup-after-cluster.sh
  RESTORE_GIT_STATUS="restored, Git catching up: PR ${url##*/} (${url})"
}
