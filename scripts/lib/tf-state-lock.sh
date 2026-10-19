# shellcheck shell=bash
# tf-state-lock.sh — the one release of a Terraform S3 state lock that a
# teardown's own dead attempt left behind. teardown-aws.sh and teardown-ec2.sh
# both source it, so the ownership rule below has one copy.
#
# The caller supplies AWS_REGION, and passes the stage 1 directory, the
# durable bucket, the state key and the epoch second at which it started.
#
# tf_release_own_stale_lock <tf-dir> <bucket> <state-key> <started-epoch> — drop
# the S3 state lock our own dead attempt left.
#
# The backend locks with a native S3 lockfile (use_lockfile). A destroy that
# dies on its context deadline is killed mid-operation and the lockfile
# survives it, so the retry never gets to run: it fails in seconds on
# "Error acquiring the state lock ... PreconditionFailed", having done no
# work at all, and the teardown reports a half-destroyed cluster that is
# STILL BILLING. Measured on the 2026-09-14 staging teardown, where attempt 1
# hit its deadline and attempt 2 died on the lock in under ten seconds.
#
# This is scoped so it can only ever release OUR OWN lock. The lockfile
# records Who as <user>@<host> and Created as an RFC3339Nano UTC timestamp
# (statemgr.LockInfo.Created is a time.Time, so it reads
# 2026-09-21T16:52:55.468346647Z). Both sides compare as epoch seconds: a
# string compare against a "%Y-%m-%d %H:%M:%S" start stamp put 'T' against
# ' ' and called every same-day lock newer than the start. The release
# happens only when Who is this process AND Created is at or after the moment
# this teardown started. A Created that cannot be read is not ours to judge,
# so it stays. Another operator's apply, or a lock older than this
# run, is left alone and the retry fails on it exactly as before, which is
# the correct outcome: a lock that is not ours is not stale, it is held.
tf_release_own_stale_lock() {
  local tf_dir="$1" bucket="$2" state_key="$3" started="$4" body id who created created_epoch
  [ -n "$bucket" ] || return 0
  body="$(mktemp "${TMPDIR:-/tmp}/tflock.XXXXXX")"
  # get-object writes the body to a FILE and its own metadata to stdout, so
  # the body must never be /dev/stdout or the two are read as one document.
  if ! aws s3api get-object --bucket "$bucket" --key "${state_key}.tflock" \
       --region "$AWS_REGION" "$body" >/dev/null 2>&1; then
    rm -f "$body"; return 0                      # no lockfile, nothing to do
  fi
  eval "$(python3 -c '
import datetime, json, re, shlex, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
for k in ("ID", "Who", "Created"):
    print("%s=%s" % (k.lower(), shlex.quote(str(d.get(k, "")))))
# RFC3339Nano to epoch seconds. fromisoformat takes at most six fraction
# digits and no trailing Z, so the fraction goes and Z becomes +00:00. A
# stamp with no zone, or one that does not parse, prints an empty epoch.
epoch = ""
try:
    t = datetime.datetime.fromisoformat(re.sub(r"\.[0-9]+", "", str(d.get("Created", ""))).replace("Z", "+00:00"))
    if t.tzinfo is not None:
        epoch = str(int(t.timestamp()))
except Exception:
    pass
print("created_epoch=%s" % shlex.quote(epoch))
' "$body" 2>/dev/null)"
  rm -f "$body"
  [ -n "${id:-}" ] || return 0
  if [ "${who:-}" != "$(whoami)@$(hostname)" ]; then
    printf '    the state lock is held by someone else (%s); leaving it alone\n' "${who:-unknown}"
    return 0
  fi
  if [ -z "${created_epoch:-}" ]; then
    printf '    the state lock carries no readable Created (%s); leaving it alone\n' "${created:-empty}"
    return 0
  fi
  if [ "$created_epoch" -lt "$started" ]; then
    printf '    the state lock predates this teardown (%s); leaving it alone\n' "$created"
    return 0
  fi
  printf '    releasing the state lock our own attempt left behind (%s)\n' "$id"
  terraform -chdir="$tf_dir" force-unlock -force "$id" >/dev/null 2>&1 \
    || printf '    force-unlock did not succeed; the retry will report the lock\n'
}
