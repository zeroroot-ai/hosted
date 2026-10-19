#!/usr/bin/env bash
# eks-post-destroy-verify.sh — ADR-0070 teardown verification (deploy#810).
#
# Runs AFTER `terraform destroy`. Two jobs:
#   1. Delete CSI-orphaned EBS volumes — PVC-backed volumes the EBS CSI driver
#      created (NOT in Terraform state), which survive `terraform destroy` and
#      keep billing. The sweep deletes ONLY volumes tagged for the cluster this
#      teardown destroyed (CLUSTER_NAME). It was account-wide (deploy#1128),
#      from the time every cluster in the account was EKS and was torn down.
#      Staging and drill now run on EC2 in the same account (ADR-0095), and a
#      volume is `available` each time a pod moves between nodes, so an
#      account-wide delete can reach a live cluster (hosted#401). A volume of
#      another cluster that is truly orphaned is not deleted here: job 2
#      counts it and fails the run, and a person decides.
#   2. Assert ZERO remaining billable resources (EKS clusters + nodegroups,
#      RDS, NAT, EC2, ELB + target groups, ENIs, EBS volumes + snapshots,
#      ElastiCache, EFS, Secrets Manager pending-deletion residue,
#      non-default VPC), then run the ADR-0070 Resource Groups Tagging API
#      sweep as the generic backstop (deploy#1404): every tagged resource in
#      the account must belong to a retained-by-design service, or fail the
#      run. Retained by design means a permanent workspace that no teardown
#      reaches (ADR-0083): stage 0 (substrate/gibson-bootstrap), the apex zone
#      (substrate/apex-zone), the org workspace (bootstrap/eks/aws-org) and the public web
#      surfaces (bootstrap/eks/public-site, ADR-0077). Nothing that bootstrap/eks/gibson created
#      is retained, and there is no tag that exempts a resource from the
#      assert (deploy#1743 deleted the teardown tag allowlist).
#      The EC2 stage 1 environments (bootstrap/ec2/gibson, ADR-0095) are also
#      kept by design: no EKS teardown reaches them. They are not named by a
#      tag someone chose. The kept set is read from that root's own
#      envs/*.tfvars, and a resource is kept only when Terraform stamped it
#      with one of those workspace names (hosted#401).
#
# FAIL-CLOSED CONTRACT (deploy#1393): "queried successfully, found zero" and
# "the query failed" are DIFFERENT results. A non-zero `aws` exit, or output
# that is not a number where a count was expected (expired credentials,
# throttling, a denied API call all produce this), marks the class UNKNOWN and
# fails the verification — it is never printed as a green ✓ 0. Before this,
# expired credentials printed eight green ticks and exited 0: "teardown
# verified" was indistinguishable from "AWS never answered", and this script
# is the only thing standing between a torn-down env and an ongoing bill.
#
# Exits non-zero (fails the teardown) if any billable resource remains OR if
# any resource class could not be established, so a stuck teardown — or a
# blind verifier — is surfaced loudly instead of silently leaking spend.
# shellcheck disable=SC2059  # repo house style: colour escapes live in the format string
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
# The cluster this teardown destroyed. Required: the volume sweep deletes, and
# a delete with no named owner is the defect hosted#401 removed.
CLUSTER_NAME="${CLUSTER_NAME:?CLUSTER_NAME is required: the orphan volume sweep deletes only volumes of the destroyed cluster (hosted#401)}"

# The workspaces kept by design: every environment of the EC2 stage 1 root.
# Read from the root's own var files, so a new EC2 environment is kept without
# an edit here, and an environment that leaves the root stops being kept.
EC2_ENVS_DIR="${EC2_ENVS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../ec2/gibson/envs" 2>/dev/null && pwd || true)}"
KEPT_WORKSPACES=""
if [ -n "$EC2_ENVS_DIR" ] && [ -d "$EC2_ENVS_DIR" ]; then
  KEPT_WORKSPACES="$(sed -nE 's/^workspace_name[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$EC2_ENVS_DIR"/*.tfvars 2>/dev/null | sort -u | grep -vx "$CLUSTER_NAME" | paste -sd, - || true)"
fi
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

leaks=0
unknowns=0
unknown_classes=""
# ARN globs of the classes an explicit probe verified clean this run. See
# arn_glob_for_label.
probed_clean=""

# arn_glob_for_label <label> — the ARN shape the named explicit probe is
# AUTHORITATIVE for, or nothing.
#
# The Tagging API index is eventually consistent: it keeps returning ARNs of
# resources that no longer exist. Measured 2026-09-14, minutes after a clean
# account sweep: 37 snapshots, an instance and a volume deleted moments
# earlier, plus 12 pod ARNs and 2 instant-fleet records belonging to a cluster
# deleted days earlier — 55 "survivors", every one of them already asserted
# gone by an explicit probe that asks the owning service. The probe is the
# authority; when it verified zero, an index entry for that class is lag, not
# a leak, and reporting it teaches the reader to ignore the backstop.
#
# A class with no probe is NOT listed here, so the backstop still fails on the
# class nobody predicted — which is its whole job.
arn_glob_for_label() {
  case "$1" in
    # EC2 instances gone means no fleet holds capacity either: Karpenter asks
    # for `instant` fleets, whose record survives the instances it launched
    # and cannot be deleted.
    "EC2 instances")      printf 'arn:aws:ec2:*:instance/*\narn:aws:ec2:*:fleet/*\n' ;;
    "EBS volumes")        printf 'arn:aws:ec2:*:volume/*\n' ;;
    "EBS snapshots")      printf 'arn:aws:ec2:*:snapshot/*\n' ;;
    "NAT gateways")       printf 'arn:aws:ec2:*:natgateway/*\n' ;;
    "Elastic IPs")        printf 'arn:aws:ec2:*:elastic-ip/*\n' ;;
    # Zero non-default VPCs proves every VPC-SCOPED object is gone with them:
    # an ENI, a security group, a subnet, a route table or a gateway cannot
    # outlive the VPC it lives in. This estate creates nothing in the default
    # VPC, so there is no other place for one of these to hide. Measured
    # 2026-09-14: 8 ENIs and a security group were reported as survivors
    # minutes after their VPC was destroyed, and `describe-network-interfaces`
    # answered InvalidNetworkInterfaceID.NotFound for every one of them.
    "Non-default VPCs")   printf 'arn:aws:ec2:*:vpc/*\narn:aws:ec2:*:vpc-endpoint/*\narn:aws:ec2:*:network-interface/*\narn:aws:ec2:*:security-group/*\narn:aws:ec2:*:subnet/*\narn:aws:ec2:*:route-table/*\narn:aws:ec2:*:internet-gateway/*\narn:aws:ec2:*:egress-only-internet-gateway/*\narn:aws:ec2:*:network-acl/*\n' ;;
    # No cluster means no nodegroup and no pod: both ARNs name a cluster that
    # the EKS probe just proved absent.
    "EKS clusters")       printf 'arn:aws:eks:*\n' ;;
    "Load balancers")     printf 'arn:aws:elasticloadbalancing:*:loadbalancer/*\n' ;;
    "ELBv2 target groups") printf 'arn:aws:elasticloadbalancing:*:targetgroup/*\n' ;;
    "ElastiCache replication groups") printf 'arn:aws:elasticache:*\n' ;;
    "EFS filesystems")    printf 'arn:aws:elasticfilesystem:*\n' ;;
    # RDS is deliberately absent: `RDS clusters` says nothing about cluster
    # SNAPSHOTS, which bill and are probed separately below.
    *) : ;;
  esac
}

# mark_unknown <label> <diagnostic> — the class could NOT be established.
# Counted separately from leaks so the summary distinguishes "still billing"
# from "AWS never answered".
mark_unknown() {
  local label="$1" why="$2"
  printf "  ${RED}?${NC} %s: UNKNOWN — %s\n" "$label" "$(printf '%s' "$why" | head -1)"
  unknowns=$((unknowns + 1))
  unknown_classes="${unknown_classes}${unknown_classes:+, }${label}"
}

# check <label> <count> — count is guaranteed numeric by the callers below.
check() {
  local label="$1" count="$2"
  if [ "$count" != "0" ]; then
    printf "  ${RED}✗${NC} %s: %s remaining\n" "$label" "$count"; leaks=$((leaks+1))
  else
    printf "  ${GREEN}✓${NC} %s: 0\n" "$label"
    local globs; globs="$(arn_glob_for_label "$label")"
    # The trailing newline matters: command substitution strips it, and
    # without it the next class's globs are glued onto this one's last line
    # and nothing ever matches.
    if [ -n "$globs" ]; then
      probed_clean="${probed_clean}${globs}
"
    fi
  fi
}

# arn_probed_clean <arn> — true when an explicit probe already verified the
# class this ARN belongs to. UNKNOWN classes never reach probed_clean, so a
# class AWS could not answer for is still swept.
arn_probed_clean() {
  local arn="$1" glob
  while IFS= read -r glob; do
    [ -z "$glob" ] && continue
    # shellcheck disable=SC2254  # the glob is the point
    case "$arn" in $glob) return 0 ;; esac
  done <<EOF_GLOBS
$probed_clean
EOF_GLOBS
  return 1
}

# check_count <label> <aws args...> — run a `length(...)` count query and
# assert zero. AWS failure or non-numeric output ⇒ UNKNOWN, never ✓.
check_count() {
  local label="$1"; shift
  local out
  if ! out="$(aws "$@" --region "$REGION" 2>&1)"; then
    mark_unknown "$label" "aws exited non-zero: ${out:-<no output>}"
    return 0
  fi
  case "$out" in
    ''|*[!0-9]*)
      mark_unknown "$label" "expected a count, got: ${out:-<empty>}"
      return 0
      ;;
  esac
  check "$label" "$out"
}

# check_count_kept <label> <aws args...> -- <extra filter args for the kept set>
# — count a class account-wide, subtract what is kept by design, assert zero.
# Both counts must be numbers. With no kept workspace this is check_count.
check_count_kept() {
  local label="$1"; shift
  local total_args=() kept_args=() seen=0 a
  for a in "$@"; do
    if [ "$a" = "--" ]; then seen=1; continue; fi
    if [ "$seen" = "0" ]; then total_args+=("$a"); else kept_args+=("$a"); fi
  done
  if [ -z "$KEPT_WORKSPACES" ] || [ "${#kept_args[@]}" -eq 0 ]; then
    check_count "$label" "${total_args[@]}"; return 0
  fi
  local total kept
  if ! total="$(aws "${total_args[@]}" --region "$REGION" 2>&1)"; then
    mark_unknown "$label" "aws exited non-zero: ${total:-<no output>}"; return 0
  fi
  if ! kept="$(aws "${total_args[@]}" "${kept_args[@]}" --region "$REGION" 2>&1)"; then
    mark_unknown "$label" "the kept-by-design count failed: ${kept:-<no output>}"; return 0
  fi
  case "$total" in ''|*[!0-9]*) mark_unknown "$label" "expected a count, got: ${total:-<empty>}"; return 0 ;; esac
  case "$kept"  in ''|*[!0-9]*) mark_unknown "$label" "expected a kept count, got: ${kept:-<empty>}"; return 0 ;; esac
  if [ "$kept" -gt "$total" ]; then
    mark_unknown "$label" "kept count ${kept} exceeds the total ${total}"; return 0
  fi
  if [ "$kept" -ne 0 ]; then
    printf "  ${YELLOW}•${NC} %s: %s kept by design (EC2 stage 1: %s)\n" "$label" "$kept" "$KEPT_WORKSPACES"
  fi
  check "$label" "$((total - kept))"
}

# list_q <outvar> <aws args...> — run a list query (tab/newline-separated IDs;
# empty output is a legitimate empty list). AWS failure ⇒ return 1 with the
# error in the outvar for the caller to mark_unknown.
list_q() {
  local __var="$1"; shift
  local out
  if out="$(aws "$@" --region "$REGION" 2>&1)"; then
    printf -v "$__var" '%s' "$out"
    return 0
  fi
  printf -v "$__var" '%s' "$out"
  return 1
}

# ---------------------------------------------------------------------------
# Job 1: CSI-orphaned EBS volume sweep, for the destroyed cluster only
# (hosted#401). A failed listing or a failed delete is a verification failure —
# the old `|| true` wrapper counted failed deletes as deleted (deploy#1393).
# ---------------------------------------------------------------------------
printf "${GREEN}▶${NC} Deleting CSI-orphaned EBS volumes of %s...\n" "$CLUSTER_NAME"
# The cluster's own ownership tag, as a KEY: `kubernetes.io/cluster/<name>`.
# The in-tree provisioner and the EBS CSI driver both write it. Only
# `available` (detached) volumes are ever touched. A wildcard here matched
# every cluster in the account.
orphans=""
orphan_sweep_ok=1
vols=""
for filt in "kubernetes.io/cluster/${CLUSTER_NAME}"; do
  if list_q vols ec2 describe-volumes \
      --filters "Name=tag-key,Values=${filt}" "Name=status,Values=available" \
      --query 'Volumes[].VolumeId' --output text; then
    orphans="${orphans} ${vols}"
  else
    mark_unknown "CSI-orphan sweep (tag ${filt})" "$vols"
    orphan_sweep_ok=0
  fi
done
if [ "$orphan_sweep_ok" = "1" ]; then
  orphans="$(printf '%s' "$orphans" | tr ' \t' '\n' | grep . | sort -u || true)"
  n=0
  for v in $orphans; do
    if err="$(aws ec2 delete-volume --volume-id "$v" --region "$REGION" 2>&1)"; then
      n=$((n+1))
    else
      mark_unknown "CSI-orphan delete ${v}" "$err"
    fi
  done
  printf "  deleted %d orphaned volume(s)\n" "$n"
fi

printf "${GREEN}▶${NC} Verifying zero remaining billable resources...\n"

# No tag exempts an instance or a volume from the assert (deploy#1743). A
# stopped instance and its root volume bill, and an account that has finished
# a teardown holds none of either.
check_count "EKS clusters"     eks list-clusters --query 'length(clusters)' --output text
check_count "RDS clusters"     rds describe-db-clusters --query 'length(DBClusters)' --output text
check_count "NAT gateways"     ec2 describe-nat-gateways --filter Name=state,Values=available --query 'length(NatGateways)' --output text
check_count_kept "EC2 instances" ec2 describe-instances --query 'length(Reservations[].Instances[])' --output text --filters Name=instance-state-name,Values=running,pending,stopping,stopped \
  -- "Name=tag:Workspace,Values=${KEPT_WORKSPACES}"
# A root volume does not always carry the workspace tag, so a kept volume is
# one attached to a kept instance.
kept_instances=""
if [ -n "$KEPT_WORKSPACES" ]; then
  if list_q kept_instances ec2 describe-instances \
      --filters "Name=tag:Workspace,Values=${KEPT_WORKSPACES}" Name=instance-state-name,Values=running,pending,stopping,stopped \
      --query 'Reservations[].Instances[].InstanceId' --output text; then
    kept_instances="$(printf '%s' "$kept_instances" | tr ' \t\n' ',' | sed -E 's/,+/,/g; s/^,//; s/,$//')"
  else
    mark_unknown "EBS volumes (kept instances)" "$kept_instances"
    kept_instances=""
  fi
fi
if [ -n "$kept_instances" ]; then
  check_count_kept "EBS volumes" ec2 describe-volumes --query 'length(Volumes)' --output text \
    -- --filters "Name=attachment.instance-id,Values=${kept_instances}"
else
  check_count "EBS volumes"    ec2 describe-volumes --query 'length(Volumes)' --output text
fi
check_count "Load balancers"   elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text
check_count_kept "Elastic IPs" ec2 describe-addresses --query 'length(Addresses)' --output text \
  -- --filters "Name=tag:Workspace,Values=${KEPT_WORKSPACES}"
check_count_kept "Non-default VPCs" ec2 describe-vpcs --query 'length(Vpcs)' --output text --filters Name=isDefault,Values=false \
  -- "Name=tag:Workspace,Values=${KEPT_WORKSPACES}"

# --- deploy#1404: the classes the criterion names (or that bill) that the
# --- original eight checks missed.

# EKS nodegroups — named in the #802 story-18 criterion. A wedged nodegroup
# can survive its cluster's DELETE_FAILED path, so count per surviving
# cluster rather than inferring from the cluster count.
eks_cluster_names="" ng_count=""
if list_q eks_cluster_names eks list-clusters --query 'clusters[]' --output text; then
  ng_total=0
  ng_ok=1
  for c in $eks_cluster_names; do
    if list_q ng_count eks list-nodegroups --cluster-name "$c" --query 'length(nodegroups)' --output text; then
      case "$ng_count" in
        ''|*[!0-9]*) mark_unknown "EKS nodegroups (${c})" "expected a count, got: ${ng_count:-<empty>}"; ng_ok=0 ;;
        *) ng_total=$((ng_total + ng_count)) ;;
      esac
    else
      mark_unknown "EKS nodegroups (${c})" "$ng_count"
      ng_ok=0
    fi
  done
  [ "$ng_ok" = "1" ] && check "EKS nodegroups" "$ng_total"
else
  mark_unknown "EKS nodegroups" "$eks_cluster_names"
fi

# ENIs — named in the criterion. Only pre-destroy handled them, and only
# before the destroy. `available` = attached to nothing: pure residue that
# blocks VPC deletion and holds any associated EIP billing.
check_count "ENIs (available)" ec2 describe-network-interfaces --filters Name=status,Values=available --query 'length(NetworkInterfaces)' --output text

# EBS snapshots. A DR snapshot is not a backup path this platform has: the
# durable bucket is (ADR-0083), so every snapshot in the account is residue.
check_count "EBS snapshots" ec2 describe-snapshots --owner-ids self --query 'length(Snapshots)' --output text

# RDS snapshots bill for their storage and outlive the cluster they were taken
# from — `describe-db-clusters` says nothing about them, so a final snapshot
# taken at teardown was invisible to every class above and showed up only as
# an anonymous ARN in the backstop (measured 2026-09-14: two prod final
# cluster snapshots from June, still billing after the 2026-08-16 teardown).
# Automated snapshots die with their cluster; manual ones do not, which is why
# only `--snapshot-type manual` is asserted. Same rule as EBS: the durable
# bucket is this platform's backup path (ADR-0083), so a DR snapshot is
# residue.
check_count "RDS cluster snapshots (manual)" rds describe-db-cluster-snapshots --snapshot-type manual --query 'length(DBClusterSnapshots)' --output text
check_count "RDS DB snapshots (manual)"      rds describe-db-snapshots --snapshot-type manual --query 'length(DBSnapshots)' --output text

# ElastiCache — both shapes the module can create.
check_count "ElastiCache replication groups" elasticache describe-replication-groups --query 'length(ReplicationGroups)' --output text
check_count "ElastiCache cache clusters"     elasticache describe-cache-clusters --query 'length(CacheClusters)' --output text

# EFS filesystems.
check_count "EFS filesystems" efs describe-file-systems --query 'length(FileSystems)' --output text

# ALB/NLB target groups — the AWS LB controller creates these out-of-band and
# they survive their load balancer.
check_count "ELBv2 target groups" elbv2 describe-target-groups --query 'length(TargetGroups)' --output text

# Secrets Manager pending-deletion residue — the class that blocked a
# re-apply on deploy#810 ("already scheduled for deletion" at the next
# standup's CreateSecret). Staging destroys with a zero recovery window, so
# anything pending deletion is residue.
check_count "Secrets Manager pending-deletion" secretsmanager list-secrets --include-planned-deletion --query 'length(SecretList[?DeletedDate])' --output text

# Route53 zones belong to stage 0 and to the apex workspace, never to this
# one (ADR-0083) — report the zones, but INSPECT their record sets (deploy#1405): a teardown kills
# external-dns with the cluster instead of draining it, so its `policy=sync`
# cleanup never runs. Stale ingress records (apex/app./www./api./docs.
# A/AAAA/CNAME) and `extdns-` ownership TXTs make the next standup's DNS
# state ambiguous — they are residue, and they fail the run. The retained
# baseline (NS/SOA, apex MX/SPF/DKIM email records, DMARC, ACM validation
# CNAMEs at `_...` names) passes. A failed zone or record listing is still a
# verification failure: "no zones printed" must not be readable as "zones
# fine".
zone_rows=""
if list_q zone_rows route53 list-hosted-zones --query 'HostedZones[].[Id,Name]' --output text; then
  if [ -z "$zone_rows" ]; then
    printf "  ${YELLOW}•${NC} Route53 zones RETAINED (by design): none\n"
  fi
  stale_records=0
  while read -r zid zname; do
    [ -z "${zid:-}" ] && continue
    zid="${zid##*/}"
    printf "  ${YELLOW}•${NC} Route53 zone RETAINED (by design): %s\n" "$zname"
    recs=""
    if ! list_q recs route53 list-resource-record-sets --hosted-zone-id "$zid" \
        --query 'ResourceRecordSets[].[Type,Name,AliasTarget.DNSName]' --output text; then
      mark_unknown "Route53 records (${zname})" "$recs"
      continue
    fi
    while read -r rtype rname rtarget; do
      [ -z "${rtype:-}" ] && continue
      case "$rtype" in
        TXT)
          case "$rname" in
            extdns-*)
              printf "    ${RED}✗${NC} stale external-dns ownership TXT: %s\n" "$rname"
              stale_records=$((stale_records + 1)) ;;
          esac ;;
        A|AAAA|CNAME)
          case "$rname" in
            "$zname"|app.*|www.*|api.*|docs.*)
              # Classify by TARGET, never by name alone. The only ingress this
              # workspace creates is the Envoy Service's load balancer, so an
              # alias to an ELB at one of these names is residue. The public
              # web surfaces (ADR-0077, bootstrap/eks/public-site) answer at
              # the apex, www. and docs. through CloudFront and are retained
              # by design — the same justification the tagging sweep's
              # `arn:aws:cloudfront:*` entry already carries, because
              # bootstrap/eks/gibson never creates a distribution. Everything
              # else at these names stays a failure, so an unrecognised target
              # is still fail-closed. Measured 2026-09-11: a clean staging
              # teardown reported the six live apex CloudFront aliases as
              # stale ingress records, which is a verifier that cries wolf on
              # the marketing site every time an environment goes away.
              case "$rtarget" in
                *.cloudfront.net|*.cloudfront.net.)
                  printf "    ${YELLOW}•${NC} public web surface RETAINED (by design, ADR-0077): %s %s\n" "$rtype" "$rname" ;;
                *)
                  printf "    ${RED}✗${NC} stale ingress record: %s %s\n" "$rtype" "$rname"
                  stale_records=$((stale_records + 1)) ;;
              esac ;;
          esac ;;
      esac
    done <<EOF_RECS
$recs
EOF_RECS
  done <<EOF_ZONES
$zone_rows
EOF_ZONES
  check "Stale Route53 ingress/extdns records" "$stale_records"
else
  mark_unknown "Route53 zones (retained-by-design report)" "$zone_rows"
fi

# ---------------------------------------------------------------------------
# ADR-0070 generic backstop (deploy#1404): Resource Groups Tagging API sweep.
# The explicit classes above are the primary probes; this catches the class
# nobody predicted — every (ever-)tagged resource in the region must belong
# to a retained-by-design service (allowlist below), or it fails the run with
# its ARN printed. Limitation, by API design: resources that have NEVER
# carried a tag are invisible to GetResources — which is why the explicit
# checks stay and this sweep is the backstop, not the primary (deploy#1404).
# ---------------------------------------------------------------------------
printf "${GREEN}▶${NC} Tagging-API sweep (ADR-0070 backstop, deploy#1404)...\n"

# Retained-by-design ARN prefixes: the permanent workspaces, keyed by the
# service each one is the only creator of, or by the name it gives its
# resources. Keep each entry justified:
#   route53         — the apex zone (substrate/apex-zone) and the sub-zone stage 0
#                     delegates (substrate/gibson-bootstrap), ADR-0083
#   acm             — the public web surfaces' certificate (ADR-0077);
#                     certificates are unbillable
#   secretsmanager  — pending-deletion residue is asserted explicitly above;
#                     a live secret bills cents and is the org workspace's
#   s3              — the durable bucket (stage 0), the org buckets
#                     (bootstrap/eks/aws-org), the public web surfaces (ADR-0077)
#   dynamodb        — the org workspace's state lock table
#   kms             — the org workspace's state keys; scheduled-deletion
#                     keys do not bill
#   iam             — global, unbillable (users/roles/policies)
#   events|schemas  — account-default EventBridge bus/registry, unbillable
#   cloudfront      — the public web surfaces (bootstrap/eks/public-site, ADR-0077);
#                     bootstrap/eks/gibson never creates a distribution
#   lambda/apigateway/sns/logs named www-* — the lead path behind the www
#                     distribution (ADR-0077, CONTEXT.md "Lead path")
arn_retained() {
  case "$1" in
    arn:aws:route53:*|arn:aws:acm:*|arn:aws:secretsmanager:*|arn:aws:s3:*) return 0 ;;
    arn:aws:dynamodb:*|arn:aws:kms:*|arn:aws:iam:*) return 0 ;;
    arn:aws:events:*|arn:aws:schemas:*) return 0 ;;
    arn:aws:cloudfront:*|arn:aws:apigateway:*) return 0 ;;
    arn:aws:lambda:*:function:www-*|arn:aws:sns:*:www-*|arn:aws:logs:*:log-group:/aws/lambda/www-*) return 0 ;;
    *) return 1 ;;
  esac
}

sweep_ok=1
all_tagged=""
list_q all_tagged resourcegroupstaggingapi get-resources \
    --query 'ResourceTagMappingList[].ResourceARN' --output text \
  || { mark_unknown "Tagging-API sweep" "$all_tagged"; sweep_ok=0; }

# Every ARN Terraform stamped with a kept workspace. One call per workspace:
# the tag filter takes one key with a list of values.
kept_arns=""
if [ "$sweep_ok" = "1" ] && [ -n "$KEPT_WORKSPACES" ]; then
  list_q kept_arns resourcegroupstaggingapi get-resources \
      --tag-filters "Key=Workspace,Values=${KEPT_WORKSPACES}" \
      --query 'ResourceTagMappingList[].ResourceARN' --output text \
    || { mark_unknown "Tagging-API sweep (kept workspaces)" "$kept_arns"; sweep_ok=0; }
fi

if [ "$sweep_ok" = "1" ]; then
  survivors=0
  lagged=0
  kept_n=0
  for arn in $all_tagged; do
    if arn_retained "$arn"; then continue; fi
    case " $(printf '%s' "$kept_arns" | tr '\t\n' '  ') " in
      *" $arn "*) kept_n=$((kept_n + 1)); continue ;;
    esac
    if arn_probed_clean "$arn"; then lagged=$((lagged + 1)); continue; fi
    printf "  ${RED}✗${NC} tagged survivor: %s\n" "$arn"
    survivors=$((survivors + 1))
  done
  if [ "$lagged" -ne 0 ]; then
    suffix=ies; if [ "$lagged" -eq 1 ]; then suffix=y; fi
    printf "  ${YELLOW}•${NC} %d stale index entr%s skipped: an explicit probe already verified the class gone\n" "$lagged" "$suffix"
  fi
  if [ "$kept_n" -ne 0 ]; then
    printf "  ${YELLOW}•${NC} %d tagged resource(s) kept by design (EC2 stage 1: %s)\n" "$kept_n" "$KEPT_WORKSPACES"
  fi
  check "Tagged survivors (outside retained-by-design services)" "$survivors"
fi

rc=0
if [ "$leaks" -ne 0 ]; then
  printf "\n${RED}✗ Teardown verification FAILED — %d resource class(es) still billing. Investigate before assuming the env is free.${NC}\n" "$leaks"
  rc=1
fi
if [ "$unknowns" -ne 0 ]; then
  printf "\n${RED}✗ Teardown NOT verified — %d class(es) could not be established (AWS query failed): %s.${NC}\n" "$unknowns" "$unknown_classes"
  printf "${RED}  Fix credentials/permissions and re-run — an unanswered query is NOT zero resources.${NC}\n"
  rc=1
fi
if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi
printf "\n${GREEN}✓ Teardown verified — zero billable resources (Route53 retained).${NC}\n"
