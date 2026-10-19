#!/usr/bin/env bash
# assert-nlb-security-group.sh: the NLB of the EKS edge has its own security
# group, and the rule that admits it to the Envoy targets references that
# group (hosted#508, ADR-0079).
#
# charts: helm/gibson/values-eks.yaml asks the AWS Load Balancer Controller
# for client-address preservation and a managed backend rule. The controller
# (v2.6 and later) is documented to give the NLB its own security group and to
# write the backend rule as a reference to it. With client addresses
# preserved, the alternative is a rule open to every address on the target
# port. This script reads AWS and proves the documented shape:
#
#   1. The load balancer behind the Service gibson-envoy has a security group.
#   2. Each target of its target groups is an ENI with a security group that
#      admits the NLB security group by reference.
#
# Read-only: describe calls only.
#
# Env:
#   NS       namespace (default gibson)
#   SERVICE  the edge Service (default gibson-envoy)
# Exit: 0 proved · 1 the shape is wrong · 2 could not run
set -euo pipefail
NS="${NS:-gibson}"
SERVICE="${SERVICE:-gibson-envoy}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cannot() { printf 'could not run: %s\n' "$*" >&2; exit 2; }

for tool in aws kubectl; do command -v "$tool" >/dev/null 2>&1 || cannot "$tool is not on PATH"; done

host="$(kubectl -n "$NS" get svc "$SERVICE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')" \
  || cannot "kubectl could not read Service ${NS}/${SERVICE}"
[ -n "$host" ] || fail "Service ${NS}/${SERVICE} has no load-balancer hostname"

lb="$(aws elbv2 describe-load-balancers --output json \
  --query "LoadBalancers[?DNSName=='${host}'] | [0]")" || cannot "aws elbv2 describe-load-balancers failed"
[ -n "$lb" ] && [ "$lb" != null ] || fail "no load balancer has the DNS name ${host}"
lb_arn="$(printf '%s' "$lb" | python3 -c 'import json,sys; print(json.load(sys.stdin)["LoadBalancerArn"])')"
nlb_sgs="$(printf '%s' "$lb" | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin).get("SecurityGroups") or []))')"
[ -n "$nlb_sgs" ] || fail "the NLB ${lb_arn} has no security group of its own. The backend rule then cannot reference it"
printf '  ✓ the NLB has its own security group: %s\n' "$nlb_sgs"

tgs="$(aws elbv2 describe-target-groups --load-balancer-arn "$lb_arn" --output text \
  --query 'TargetGroups[].TargetGroupArn')" || cannot "aws elbv2 describe-target-groups failed"
[ -n "$tgs" ] || fail "the NLB ${lb_arn} has no target group"

checked=0
for tg in $tgs; do
  ips="$(aws elbv2 describe-target-health --target-group-arn "$tg" --output text \
    --query 'TargetHealthDescriptions[].Target.Id')" || cannot "aws elbv2 describe-target-health failed"
  for ip in $ips; do
    target_sgs="$(aws ec2 describe-network-interfaces --output text \
      --filters "Name=addresses.private-ip-address,Values=${ip}" \
      --query 'NetworkInterfaces[].Groups[].GroupId')" || cannot "aws ec2 describe-network-interfaces failed"
    [ -n "$target_sgs" ] || fail "target ${ip} of ${tg} has no ENI with a security group"
    referencing="$(aws ec2 describe-security-groups --output text \
      --group-ids $target_sgs \
      --query "SecurityGroups[?IpPermissions[?UserIdGroupPairs[?contains('${nlb_sgs}', GroupId)]]].GroupId")" \
      || cannot "aws ec2 describe-security-groups failed"
    [ -n "$referencing" ] \
      || fail "target ${ip} has the security groups ${target_sgs}, and none admits the NLB security group ${nlb_sgs} by reference"
    printf '  ✓ target %s: security group %s admits the NLB security group by reference\n' "$ip" "$referencing"
    checked=$((checked + 1))
  done
done
[ "$checked" -gt 0 ] || fail "the target groups of ${lb_arn} hold no target, so no backend rule was checked"
printf 'PASS: the NLB has its own security group, and %d target(s) admit it by reference\n' "$checked"
