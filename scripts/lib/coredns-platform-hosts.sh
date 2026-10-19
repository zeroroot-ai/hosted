# shellcheck shell=bash
# coredns-platform-hosts.sh — each bringup gives CoreDNS one record that maps
# the platform's public hosts to the Envoy Service (hosted#397, ADR-0092).
# Sourced, not executed.
#
# WHY
#
# Some in-cluster workloads reach the platform the way an outside client does,
# through the authenticated edge on api.<domain>: plugins, setec sandboxes and
# the e2e runner. Inside the cluster that name must lead to Envoy without a
# trip through public DNS: kind has no public record at all, and on a cloud
# substrate the public answer leaves the cluster and comes back through the
# load balancer, which collapses every in-cluster caller onto one source
# address for rate limits.
#
# The first form of this record (hosted#145) was a `hosts` block that named
# Envoy's pinned ClusterIP. It tied the record to a pinned address, and the
# pin is one of the workarounds ADR-0092 removes. The owner decided on
# 2026-10-05 (hosted#186): the record maps the host to the Service NAME, never
# to an address. So it is a CoreDNS `rewrite`: the question for api.<domain>
# becomes the question for the Service, the kubernetes plugin answers with
# whatever address the Service has today, and `answer auto` puts the asked
# name back in the answer.
#
# The bringup verb owns the record, because the same verb owns the cluster.
# The chart owns nothing here.
#
# Functions:
#   platform_host_rules <service-fqdn> <host>...   pure; prints one rewrite
#       line for each host. Exit 2 when the target is an address or is not a
#       Service name, and when no host is given.
#   corefile_with_platform_hosts <corefile-text> <service-fqdn> <host>...
#       pure; prints the Corefile with the rules inside the `.:53` server
#       block. A block this function wrote before is replaced, never doubled.
#       Exit 2 when the text has no `.:53 {` server.
#   values_domain <values-file>...   the platform domain from the values files
#       in install order, last wins (gibson-workloads.global.domain, then
#       global.domain). Exit 2 when none names one.
#   coredns_publish_platform_hosts <corefile|custom> <service-fqdn> <host>...
#       apply the record and restart CoreDNS. `corefile` rewrites
#       kube-system/coredns (kind, k3d). `custom` writes the
#       kube-system/coredns-custom ConfigMap that k3s imports into its server
#       block (EC2 with k3s).
#
# The record is proven by its effect in charts exit-test-baseline-install: a pod asks
# cluster DNS for the API host and must get the address of the Envoy Service.

PLATFORM_HOSTS_BEGIN="# BEGIN platform hosts (hosted#397)"
PLATFORM_HOSTS_END="# END platform hosts (hosted#397)"

platform_host_rules() {
  local target="$1"; shift || true
  [ $# -gt 0 ] || { echo "platform_host_rules: no host given" >&2; return 2; }
  python3 - "$target" "$@" <<'PY'
import re, sys
target, hosts = sys.argv[1], sys.argv[2:]
if re.fullmatch(r"[0-9.]+|[0-9a-fA-F:]+", target):
    sys.stderr.write(f"platform_host_rules: the target {target} is an address. The record names the Envoy Service, never an address (hosted#186)\n")
    sys.exit(2)
if not re.fullmatch(r"[a-z0-9-]+\.[a-z0-9-]+\.svc\.cluster\.local", target):
    sys.stderr.write(f"platform_host_rules: the target {target} is not <service>.<namespace>.svc.cluster.local\n")
    sys.exit(2)
for h in hosts:
    if not re.fullmatch(r"[a-z0-9-]+(\.[a-z0-9-]+)+", h):
        sys.stderr.write(f"platform_host_rules: {h} is not a host name\n")
        sys.exit(2)
    print(f"rewrite name exact {h} {target} answer auto")
PY
}

corefile_with_platform_hosts() {
  local text="$1" target="$2"; shift 2 || true
  local rules
  rules="$(platform_host_rules "$target" "$@")" || return 2
  python3 - "$text" "$PLATFORM_HOSTS_BEGIN" "$PLATFORM_HOSTS_END" "$rules" <<'PY'
import re, sys
text, begin, end, rules = sys.argv[1:5]
block = f"    {begin}\n" + "".join(f"    {r}\n" for r in rules.splitlines()) + f"    {end}\n"
# A block this function wrote before is replaced, so a second bringup over the
# same ConfigMap never doubles it.
text = re.sub(rf"^[ \t]*{re.escape(begin)}\n.*?^[ \t]*{re.escape(end)}\n", "", text, flags=re.S | re.M)
m = re.search(r"^\.:53 \{\n", text, flags=re.M)
if not m:
    sys.stderr.write("corefile_with_platform_hosts: the Corefile has no `.:53 {` server block; refusing to guess where the record goes\n")
    sys.exit(2)
sys.stdout.write(text[: m.end()] + block + text[m.end():])
PY
}

values_domain() {
  [ $# -gt 0 ] || { echo "values_domain: no values files given" >&2; return 2; }
  python3 - "$@" <<'PY'
import sys, yaml
domain = ""
for path in sys.argv[1:]:
    try:
        data = yaml.safe_load(open(path)) or {}
    except FileNotFoundError:
        sys.stderr.write(f"values_domain: {path} does not exist\n"); sys.exit(2)
    for keys in (("gibson-workloads", "global", "domain"), ("global", "domain")):
        node = data
        for k in keys:
            node = node.get(k) if isinstance(node, dict) else None
        if isinstance(node, str) and node:
            domain = node
if not domain:
    sys.stderr.write("values_domain: no values file names global.domain; the record would point at nothing\n")
    sys.exit(2)
print(domain)
PY
}

coredns_publish_platform_hosts() {
  local mode="$1" target="$2"; shift 2 || true
  case "$mode" in
    corefile)
      local current rewritten
      current="$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')" \
        || { echo "coredns_publish_platform_hosts: cannot read kube-system/coredns" >&2; return 1; }
      [ -n "$current" ] || { echo "coredns_publish_platform_hosts: kube-system/coredns carries no Corefile" >&2; return 1; }
      rewritten="$(corefile_with_platform_hosts "$current" "$target" "$@")" || return 2
      kubectl -n kube-system create configmap coredns --from-literal=Corefile="$rewritten" \
        --dry-run=client -o yaml \
        | kubectl apply --server-side --force-conflicts --field-manager=bringup-platform-hosts -f - >/dev/null
      ;;
    custom)
      # k3s mounts kube-system/coredns-custom and imports every *.override key
      # into its `.:53` server block. The bringup owns this one key.
      local rules
      rules="$(platform_host_rules "$target" "$@")" || return 2
      kubectl -n kube-system create configmap coredns-custom \
        --from-literal=platform-hosts.override="$rules" --dry-run=client -o yaml \
        | kubectl apply --server-side --force-conflicts --field-manager=bringup-platform-hosts -f - >/dev/null
      ;;
    *)
      echo "coredns_publish_platform_hosts: unknown mode ${mode}; use corefile or custom" >&2; return 2 ;;
  esac
  kubectl -n kube-system rollout restart deployment/coredns >/dev/null
  kubectl -n kube-system rollout status deployment/coredns --timeout=120s >/dev/null
}
