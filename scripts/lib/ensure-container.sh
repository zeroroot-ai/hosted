#!/usr/bin/env bash
# ensure-container.sh — one stage 0 container, keyed by its run configuration.
#
# Sourced by bootstrap/kind/substrate/substrate.sh. The caller defines NET
# (the Docker network) and the three printers say, step and die.
#
# WHY THE KEY IS THE WHOLE CONFIGURATION
# --------------------------------------
# The first version compared the image and the address only. A container
# reads its --env-file ONCE, at `docker run`, so when the state directory
# was regenerated on 2026-09-05 (a new MinIO root credential, a new Mailpit
# AUTH table) the containers from 2026-09-01 kept running with the old
# values, and stage 0 died at the bucket step with:
#
#   mc: <ERROR> Unable to make bucket `local/gibson-kind`. The request
#   signature we calculated does not match the signature you provided.
#
# That message names nothing. The fix is to fingerprint everything that
# `docker run` would be given — the network, the image, the address, every
# argument, and the CONTENT of every --env-file — and to store that
# fingerprint on the container as a label. A container whose label differs
# from the fingerprint of the run this script is about to do is recreated
# on its data. A container with no label at all predates this file and is
# recreated too.
#
# The label is keyed by content, never by a path or a timestamp: rewriting
# an env-file with the same bytes changes nothing, and moving the state
# directory with its files intact changes only the volume arguments, which
# is a real change.

CONFIG_LABEL="zeroroot.ai/substrate-config"

# container_config_fingerprint IMAGE IP ARGS... — sixteen hex characters
# over the network, the image, the address, every argument in order, and
# the sha256 of each --env-file's content.
container_config_fingerprint() {
  local prev="" a
  # Refuse BEFORE the pipeline: a `die` inside a command substitution or a
  # pipeline ends that subshell only, and the caller would read an empty
  # or partial fingerprint as a real one.
  for a in "$@"; do
    if [ "$prev" = "--env-file" ] && [ ! -r "$a" ]; then
      die "--env-file $a is not readable, so its container cannot be fingerprinted"
    fi
    prev="$a"
  done
  prev=""
  {
    printf 'net=%s\n' "$NET"
    for a in "$@"; do
      printf 'arg=%s\n' "$a"
      if [ "$prev" = "--env-file" ]; then
        printf 'env-file-sha256=%s\n' "$(sha256sum < "$a" | cut -d' ' -f1)"
      fi
      prev="$a"
    done
  } | sha256sum | cut -c1-16
}

# ensure_container NAME IMAGE IP -- <docker run args after --network/--ip>
ensure_container() {
  local name="$1" image="$2" ip="$3"; shift 4
  local want have
  # The refusal above runs in this shell, not in the substitution, so a
  # missing env-file stops here whether or not the caller set -e.
  container_config_fingerprint "$image" "$ip" "$@" >/dev/null
  want="$(container_config_fingerprint "$image" "$ip" "$@")"
  if docker container inspect "$name" >/dev/null 2>&1; then
    have="$(docker inspect -f "{{index .Config.Labels \"$CONFIG_LABEL\"}}" "$name")"
    if [ "$have" = "$want" ]; then
      if [ "$(docker inspect -f '{{.State.Running}}' "$name")" != "true" ]; then
        docker start "$name" >/dev/null
      fi
      say "$name running at $ip (config $want)"
      return
    fi
    step "$name was started from a different configuration (${have:-no label} vs $want), recreating on its data"
    docker rm -f "$name" >/dev/null
  fi
  local err
  if ! err="$(docker run -d --name "$name" --restart unless-stopped \
      --network "$NET" --ip "$ip" \
      --label zeroroot.ai/substrate=kind --label "$CONFIG_LABEL=$want" "$@" 2>&1)"; then
    case "$err" in
      *"user configured subnets"*)
        die "Docker network $NET exists with an IPv4 subnet Docker chose itself, so a pinned address is refused. Delete every kind cluster (kind delete clusters --all), remove the network (docker network rm $NET) and re-run: stage 0 recreates it with an explicit subnet." ;;
      *) die "docker run $name failed: $err" ;;
    esac
  fi
  say "$name started at $ip (config $want)"
}
