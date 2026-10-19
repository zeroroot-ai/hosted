# shellcheck shell=bash
# ssm-forward.sh — the ONE way a bringup verb forwards a cluster API through
# SSM, and the one way it tears that forward down (hosted#209).
#
# Sourced, never executed:
#   . "$(dirname "$0")/lib/ssm-forward.sh"
#
# WHY THIS EXISTS
# ---------------
# `aws ssm start-session` does not forward anything itself. It starts
# session-manager-plugin, and the plugin holds the local port. Both verbs used
# to background the aws command, record `$!`, and kill that pid on exit. That
# killed aws and left the plugin alive: an orphan holding 127.0.0.1:6443 and
# pointed at an instance that no longer exists.
#
# Measured 2026-09-29 on the hosted#209 rebuild: the first teardown run left
# its plugin behind. The second teardown run could not bind the port. The
# recreate could not bind it either, so its kubectl went through the orphan
# to the destroyed instance, and stage 1 died with "the API did not answer
# through the SSM forward within 120s" although the new node answered on a
# fresh forward at once.
#
# Two rules, both enforced here:
#   1. A forward starts in its OWN process group, and the stop kills the
#      group. The plugin dies with the aws command, every time.
#   2. A forward REFUSES a local port that is already bound, and names the
#      holder. A busy port means a stale forward, and a stale forward sends
#      every kubectl call to the wrong cluster while looking like a timeout.

# ssm_forward_start <instance-id> <region> <local-port> [remote-port]
#
# Sets SSM_FORWARD_PGID. Returns 1, with the reason on stderr, when the local
# port is bound or the session cannot start. It does not wait for the API:
# the caller polls kubectl against its own deadline, as before.
ssm_forward_start() {
  local instance="$1" region="$2" local_port="$3" remote_port="${4:-6443}" holder
  if [ -z "$instance" ] || [ -z "$region" ] || [ -z "$local_port" ]; then
    echo "ssm_forward_start: usage: <instance-id> <region> <local-port> [remote-port]" >&2
    return 1
  fi

  holder="$(ss -ltnpH "sport = :${local_port}" 2>/dev/null | sed -n 's/.*users:(("\([^"]*\)",pid=\([0-9]*\).*/\1 (pid \2)/p' | head -1)"
  if [ -z "$holder" ]; then
    holder="$(ss -ltnH "sport = :${local_port}" 2>/dev/null | head -1)"
  fi
  if [ -n "$holder" ]; then
    echo "ssm_forward_start: 127.0.0.1:${local_port} is already bound by ${holder}. A bound port is a stale forward from an earlier run, and a forward through it reaches the wrong cluster. Stop that process, then run again" >&2
    return 1
  fi

  # setsid: the aws command becomes a session and process-group leader, and
  # session-manager-plugin inherits the group. The group id is read from
  # INSIDE the new session, never from `$!`: with job control on (an
  # interactive shell, `set -m`) a background job is already a group leader,
  # setsid forks instead of exec-ing, and `$!` names a process that has
  # exited. Measured 2026-09-29: a stop keyed on `$!` from an interactive
  # shell left the plugin on the port, the exact leak this file exists to end.
  local pidfile
  pidfile="$(mktemp)" || return 1
  # shellcheck disable=SC2016  # the $$ and $1 expand inside the new session, on purpose
  setsid bash -c 'echo "$$" > "$1"; shift; exec aws "$@"' _ "$pidfile" \
    ssm start-session --target "$instance" --region "$region" \
    --document-name AWS-StartPortForwardingSession \
    --parameters "portNumber=${remote_port},localPortNumber=${local_port}" >/dev/null 2>&1 &
  local _i
  for _i in $(seq 1 50); do
    [ -s "$pidfile" ] && break
    sleep 0.1
  done
  SSM_FORWARD_PGID="$(cat "$pidfile" 2>/dev/null)"
  rm -f "$pidfile"
  if [ -z "$SSM_FORWARD_PGID" ]; then
    echo "ssm_forward_start: the forward did not report its process group within 5s" >&2
    return 1
  fi
  export SSM_FORWARD_PGID
  return 0
}

# ssm_forward_stop — kill the whole forward group. Safe to call when nothing
# was started. Waits until the group is gone, so the port is free on return.
ssm_forward_stop() {
  [ -n "${SSM_FORWARD_PGID:-}" ] || return 0
  kill -- "-${SSM_FORWARD_PGID}" 2>/dev/null || true
  local _i
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 -- "-${SSM_FORWARD_PGID}" 2>/dev/null || break
    sleep 0.2
  done
  kill -KILL -- "-${SSM_FORWARD_PGID}" 2>/dev/null || true
  unset SSM_FORWARD_PGID
  return 0
}
