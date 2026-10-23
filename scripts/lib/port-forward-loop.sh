#!/usr/bin/env bash
# port-forward-loop.sh: the one port-forward loop of the exit tests
# (hosted#745). Source it, then:
#
#   pf_loop <namespace> <target> <local-port>:<remote-port>
#   pf_stop_all
#
# pf_loop starts a loop that keeps `kubectl port-forward` up on 127.0.0.1,
# and starts it again a second after it ends. The loop runs in a process
# group of its own (setsid), and its group id goes in PF_PIDS.
#
# pf_stop_all stops each loop by its whole group. A kill of the loop alone
# leaves the kubectl child alive after the test ends (found in the review of
# hosted#741). Call it from the EXIT trap of the test.
#
# Requires: setsid (util-linux), kubectl.

# The group ids of the loops, and of any other process the test adds to
# stop at the end. pf_stop_all kills a pid that is not a group by itself.
PF_PIDS=()

command -v setsid >/dev/null 2>&1 \
  || { echo "port-forward-loop.sh: setsid (util-linux) is not on PATH, so a loop cannot get a process group of its own" >&2; exit 2; }


# THE TRANSPORT (hosted#57). kubectl port-forward reads its own variable,
# KUBECTL_PORT_FORWARD_WEBSOCKETS, and this repository leaves it at the
# kubectl default. It needs no gate like KUBECTL_REMOTE_COMMAND_WEBSOCKETS:
#   - The exec defect (hosted#10) is a stream that loses its last bytes while
#     kubectl still exits 0. That is silent because the exit code is the
#     answer the caller reads.
#   - A port-forward has no exit code that a caller reads. It carries a TCP
#     connection. Each caller reads a framed answer through it (an HTTP status
#     and a body). A lost stream closes or resets that connection, so the
#     caller gets a connection error or a short body and fails by name.
# The one thing a drop could hide is the reason. So the loop prints each
# error line of kubectl and each end of kubectl on stderr, with the target.
#
# The exit tests run with no job control, so a background child is not a
# group leader, and setsid runs in place: $! is then the pid, the group id and
# the session id of the loop. With job control on (set -m) setsid would fork,
# and $! would name a parent that has ended. pf_loop refuses that shell.
pf_loop() {
  local ns="$1" target="$2" ports="$3"
  case "$-" in *m*) echo "pf_loop: job control is on, so setsid would fork and the loop could not be stopped" >&2; return 2 ;; esac
  setsid bash -c '
    while true; do
      kubectl -n "$1" port-forward --address 127.0.0.1 "$2" "$3" 2>&1 >/dev/null \
        | sed -u "s|^|port-forward $1/$2: |" >&2
      echo "port-forward $1/$2 ended (kubectl exit ${PIPESTATUS[0]}), it starts again in 1 s" >&2
      sleep 1
    done' pf-loop "$ns" "$target" "$ports" </dev/null &
  PF_PIDS+=("$!")
}

pf_stop_all() {
  local pid
  for pid in "${PF_PIDS[@]}"; do
    [ -n "$pid" ] || continue
    # The negative id names the process group: the loop and its kubectl.
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  done
  PF_PIDS=()
}
