#!/usr/bin/env bash
# eks-pre-destroy.sh — EKS teardown preflight (deploy#567 S11).
#
# Clears the out-of-band resources that block `terraform destroy` (admission
# webhooks, Karpenter nodes, controller-made load balancers, ENIs and security
# groups) and prints a summary before any destructive action. Nothing is carved out of the destroy: both teardown
# modes destroy stage 1 whole (ADR-0083). What must outlive a cluster lives in
# stage 0 (substrate/gibson-bootstrap) or in a permanent workspace (substrate/apex-zone),
# never in this workspace's state.
#
# REQUIRES: CONFIRM=reset environment variable.
#
# Usage: CONFIRM=reset ./scripts/eks-pre-destroy.sh
#
# Must be run from the bootstrap/eks/gibson/ directory. WORKSPACE
# (zeroroot-ai-staging | zeroroot-ai-prod) is REQUIRED — this script disables
# deletion protection, and since the two forked roots collapsed into one
# (deploy#1397) there is no directory left to infer an env from.
# The teardown verb (deploy#1746) always passes it.
# kubectl must be configured to reach the live cluster.

set -euo pipefail

WORKSPACE="${WORKSPACE:?WORKSPACE is required (zeroroot-ai-staging | zeroroot-ai-prod) — refusing to guess which environment to prepare for destroy}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

if [[ "${CONFIRM:-}" != "reset" ]]; then
  printf "${RED}✗${NC} CONFIRM=reset required to run pre-destroy preflight.\n"
  printf "    Run: CONFIRM=reset ./scripts/eks-pre-destroy.sh\n"
  exit 1
fi

printf "${YELLOW}EKS pre-destroy preflight${NC}\n\n"

# Step 1a: Sweep service-backed admission webhooks (deploy#1592).
#
# MUST BE THE FIRST DESTRUCTIVE STEP. Everything below this line — deleting the
# Karpenter NodePools, deleting the LoadBalancer Services, terminating the
# nodes — removes pods, and the moment a webhook's backing pods go away its
# ValidatingWebhookConfiguration starts refusing every request it gates,
# including the deletions `terraform destroy` is about to issue. On 2026-08-16
# that stranded four ClusterSecretStore CRs behind external-secrets'
# `secretstore-validate` and cost two ~40-minute teardown attempts.
#
# Sweeping first, while the backing pods are still up, is what makes the rest
# of the teardown deletable. The sweep NEVER fails this script: it exits 0 even
# when the cluster is unreachable (`|| true` here is belt-and-braces on top of
# the script's own contract — see its SAFETY CONTRACT header).
bash "$(dirname "$0")/eks-sweep-admission-webhooks.sh" || true
printf "\n"

# Step 1b: Delete the Karpenter NodePool + EC2NodeClass FIRST, while the
# cluster is still up, so Karpenter deprovisions its own nodes AND removes its
# k8s-traffic-* security group. If that SG survives the cluster it cross-
# references the EKS primary cluster SG, blocking EKS from deleting it on
# cluster teardown — and the orphaned SGs then hang the VPC delete for ~hours
# ("Still destroying... aws_vpc"). #747.
printf "${GREEN}▶${NC} Deleting Karpenter NodePool/EC2NodeClass (drain Karpenter nodes + SG)...\n"
kubectl delete nodepool.karpenter.sh --all --wait=false 2>/dev/null && printf "  nodepools deleting\n" || true
kubectl delete ec2nodeclass.karpenter.k8s.aws --all --wait=false 2>/dev/null && printf "  ec2nodeclasses deleting\n" || true

# Step 1c: Delete LoadBalancer Services and Ingresses so the AWS LB controller
# deprovisions their NLBs, ALBs, target groups and ENIs BEFORE the VPC is
# destroyed (else VPC delete fails on in-use ENIs).
#
# Then WAIT for the controller to finish. The controller clears
# `service.k8s.aws/resources` (and the Ingress equivalent) only after the cloud
# objects are gone, so the object leaving the API server IS the completion
# signal. Without the wait the destroy races the controller and kills it
# mid-cleanup: measured on the 2026-09-14 staging teardown, which left target
# group k8s-gibson-gibsonen-31e3236765 behind in a VPC that no longer exists,
# a survivor the fail-closed verification then had to report.
#
# Bounded, and a timeout is NOT fatal. An orphan target group costs nothing and
# the post-destroy verification names it, whereas refusing to destroy a cluster
# because one controller is slow leaves the whole cluster billing.
LB_DRAIN_TIMEOUT="${LB_DRAIN_TIMEOUT:-300}"
printf "${GREEN}▶${NC} Deleting LoadBalancer Services and Ingresses (NLB/ALB/target-group/ENI cleanup)...\n"
kubectl get svc -A --no-headers 2>/dev/null | awk '$3=="LoadBalancer"{print $1, $2}' \
  | while read -r ns nm; do kubectl delete svc "$nm" -n "$ns" --wait=false 2>/dev/null \
      && printf "  deleted svc %s/%s\n" "$ns" "$nm"; done || true
kubectl get ingress -A --no-headers 2>/dev/null | awk '{print $1, $2}' \
  | while read -r ns nm; do kubectl delete ingress "$nm" -n "$ns" --wait=false 2>/dev/null \
      && printf "  deleted ingress %s/%s\n" "$ns" "$nm"; done || true

printf "${GREEN}▶${NC} Waiting up to %ss for the load balancer controller to release its cloud objects...\n" "$LB_DRAIN_TIMEOUT"
lb_deadline=$(( $(date +%s) + LB_DRAIN_TIMEOUT ))
while :; do
  lb_left=$( { kubectl get svc -A --no-headers 2>/dev/null | awk '$3=="LoadBalancer"'
               kubectl get ingress -A --no-headers 2>/dev/null; } | wc -l )
  if [ "${lb_left:-0}" -eq 0 ]; then
    printf "  ✓ every LoadBalancer Service and Ingress is gone: the controller released its cloud objects\n"
    break
  fi
  if [ "$(date +%s)" -ge "$lb_deadline" ]; then
    printf "  %s object(s) still present after %ss. The destroy continues; the post-destroy verification reports any survivor.\n" \
      "$lb_left" "$LB_DRAIN_TIMEOUT"
    break
  fi
  sleep 5
done

# Step 1c1: unblock namespaces stuck Terminating, whatever is pinning them.
#
# THE CLASS, in one sentence: a finalizer whose owning controller this destroy
# has already removed can never be cleared, so whatever carries it pins its
# namespace open for ever and terraform blocks on the namespace until its
# context deadline.
#
# It is the same class as the admission-webhook deadlock (deploy#1592) and the
# pod whose kubelet is gone (deploy#1800). Measured on staging inside
# deploy#1746, in FIVE different kinds across three teardowns:
#
#   externalsecrets.external-secrets.io   externalsecret-cleanup       (ESO)
#   challenges.acme.cert-manager.io       acme.cert-manager.io/...     (cert-manager)
#   oidcclients.gibson.zeroroot.ai        platform-operator...         (platform-operator)
#   targetgroupbindings.elbv2.k8s.aws     elbv2.k8s.aws/resources      (LB controller)
#   services                              service.k8s.aws/resources    (LB controller)
#
# Naming the kinds one at a time was the wrong shape: the first version of
# this step listed only ExternalSecrets and the very next teardown died on
# cert-manager Challenges. So this asks the API server WHAT IS ACTUALLY LEFT
# rather than guessing, which covers every kind a future chart adds.
#
# Scoped hard, and safe only because of the scope:
#   * ONLY namespaces already in Terminating. A namespace nobody asked to
#     delete is untouched.
#   * ONLY inside a teardown, after the decision to destroy the cluster, so
#     no controller is owed the chance to finish its cleanup.
# On the FIRST pass nothing is Terminating yet and this is a no-op; it does
# its work when the destroy retry re-runs the sweep (deploy#1803), which is
# exactly when a namespace is stuck.
printf "${GREEN}▶${NC} Unblocking namespaces stuck Terminating (finalizers whose controller is gone)...\n"
for ns in $(kubectl get ns -o jsonpath='{range .items[?(@.status.phase=="Terminating")]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  [ -n "${ns:-}" ] || continue
  printf "  namespace %s is Terminating; clearing what is left\n" "$ns"
  # Every namespaced kind the server serves and can list, asked of the server
  # rather than hard-coded. `|| true` on each step: a kind that cannot be
  # listed is one that cannot be pinning anything either.
  #
  # ONLY objects that actually carry a finalizer. The first version patched
  # every object of every kind, which is O(everything in the namespace) at one
  # kubectl round trip each — and a merge-patch clearing finalizers SUCCEEDS on
  # an object that has none, so it also printed "cleared finalizers on" for
  # every one of them. Measured on the 2026-09-14 staging teardown: 1721
  # patches, 1389 of them on Events, which cannot hold a finalizer and cannot
  # pin a namespace. Filtering on the server turns that into the handful of
  # objects that are actually stuck, and makes the line it prints true.
  for kind in $(kubectl api-resources --namespaced=true --verbs=list -o name 2>/dev/null); do
    for name in $(kubectl -n "$ns" get "$kind" \
        -o jsonpath='{range .items[?(@.metadata.finalizers)]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
      [ -n "${name:-}" ] || continue
      kubectl -n "$ns" patch "$kind" "$name" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 \
        && printf "    cleared finalizers on %s/%s\n" "$kind" "$name"
    done
  done
done || true

# Step 1c2: force-delete pods that are stuck Terminating, so a namespace can
# finish deleting.
#
# A pod whose node is already gone never has its deletion confirmed: the
# kubelet that owned it is not there to confirm it, so the API server keeps
# the object and the namespace stays Terminating forever. Terraform then
# blocks on `kubernetes_namespace.gibson` until its context deadline and the
# whole destroy fails:
#
#   NamespaceDeletionContentFailure: Failed to delete all resource types,
#   1 remaining: unexpected items still remain in namespace: gibson
#   for gvr: /v1, Resource=pods
#   Error: context deadline exceeded
#
# Measured on staging 2026-09-02 (deploy#1746): ONE pod, gibson-openbao-0,
# Failed with a deletion timestamp, left the estate half-destroyed and still
# billing after the destroy had already used its one retry.
#
# `--grace-period=0 --force` drops the object without waiting for a kubelet
# that cannot answer. That is safe HERE and nowhere else: this script runs
# only inside a teardown, after the decision to destroy the cluster is made,
# so there is no workload whose graceful shutdown is still owed anything.
# Scoped to pods already carrying a deletionTimestamp — a pod nobody asked to
# delete is left alone.
printf "${GREEN}▶${NC} Force-deleting pods stuck Terminating (namespace deletion unblocker)...\n"
kubectl get pods -A -o \
  'jsonpath={range .items[?(@.metadata.deletionTimestamp)]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' \
  2>/dev/null | while read -r ns nm; do
    [ -n "${ns:-}" ] && [ -n "${nm:-}" ] || continue
    kubectl delete pod "$nm" -n "$ns" --grace-period=0 --force --wait=false >/dev/null 2>&1 \
      && printf "  force-deleted pod %s/%s\n" "$ns" "$nm"
  done || true

# Step 1d: forcibly drain out-of-band VPC dependencies that Terraform does NOT
# own and that block subnet/VPC deletion (#747):
#   - Karpenter-launched EC2 nodes (created out-of-band, not via the managed
#     nodegroup), whose ENIs keep the private subnets in use.
#   - any leftover k8s-* NLBs the AWS LB controller didn't finish deprovisioning
#     before the cluster went away (the controller may already be gone).
# Then wait until no instances + no ELB ENIs remain so `terraform destroy` can
# delete the subnets/NAT/VPC on the first pass.
VPC_ID="$(terraform output -raw vpc_id 2>/dev/null || true)"
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  printf "${GREEN}▶${NC} Draining out-of-band VPC deps in %s (Karpenter nodes + NLBs)...\n" "$VPC_ID"
  KARP_IDS="$(aws ec2 describe-instances \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag-key,Values=karpenter.sh/nodepool" \
              "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)"
  if [ -n "$KARP_IDS" ]; then
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --instance-ids $KARP_IDS >/dev/null 2>&1 \
      && printf "  terminating Karpenter nodes: %s\n" "$KARP_IDS"
  fi
  for lb_arn in $(aws elbv2 describe-load-balancers \
      --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null || true); do
    # The envoy NLB sets deletion_protection.enabled=true (chart annotation), so
    # delete-load-balancer 400s until protection is disabled first (deploy#810).
    aws elbv2 modify-load-balancer-attributes --load-balancer-arn "$lb_arn" \
      --attributes Key=deletion_protection.enabled,Value=false >/dev/null 2>&1 || true
    aws elbv2 delete-load-balancer --load-balancer-arn "$lb_arn" >/dev/null 2>&1 \
      && printf "  deleted load balancer %s\n" "${lb_arn##*/}"
  done
  printf "  waiting for instances + ELB ENIs to clear..."
  for _ in $(seq 1 30); do
    insts="$(aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC_ID" \
      "Name=instance-state-name,Values=running,pending,stopping" \
      --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo 0)"
    enis="$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" \
      "Name=description,Values=ELB*" --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo 0)"
    [ "$insts" = "0" ] && [ "$enis" = "0" ] && break
    sleep 10
  done
  printf " done\n"

  # Step 1e: sweep orphaned k8s security groups (#1127). Karpenter
  # (k8s-traffic-*) and the AWS LB controller (k8s-<ns>-*) create SGs
  # out-of-band; the NodePool/Service deletes above are issued --wait=false,
  # so both controllers are usually torn down before they GC their SGs. The
  # survivors cross-reference each other AND the EKS cluster SG, which wedges
  # the VPC delete (DependencyViolation) after every other dependency is gone.
  # Revoke every rule on every non-default SG first (breaks the cross-
  # references), then best-effort delete. TF-owned SGs that are still in use
  # fail the delete harmlessly — terraform destroy remains their owner.
  printf "${GREEN}▶${NC} Sweeping orphaned k8s security groups in %s...\n" "$VPC_ID"
  SG_IDS="$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null || true)"
  for sg in $SG_IDS; do
    perms="$(aws ec2 describe-security-groups --group-ids "$sg" \
      --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null || echo '[]')"
    if [ -n "$perms" ] && [ "$perms" != "[]" ]; then
      aws ec2 revoke-security-group-ingress --group-id "$sg" \
        --ip-permissions "$perms" >/dev/null 2>&1 || true
    fi
    eperms="$(aws ec2 describe-security-groups --group-ids "$sg" \
      --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null || echo '[]')"
    if [ -n "$eperms" ] && [ "$eperms" != "[]" ]; then
      aws ec2 revoke-security-group-egress --group-id "$sg" \
        --ip-permissions "$eperms" >/dev/null 2>&1 || true
    fi
  done
  for sg in $SG_IDS; do
    aws ec2 delete-security-group --group-id "$sg" >/dev/null 2>&1 \
      && printf "  deleted SG %s\n" "$sg" || true
  done
fi

# Step 2: Print summary. Nothing is detached from state: `terraform destroy`
# owns every resource this workspace created, and destroys all of them.
printf "\n${YELLOW}Pre-destroy summary${NC}\n"
printf "  Admission webhooks swept, Karpenter nodes and controller-made\n"
printf "  load balancers draining, orphaned security groups cleared.\n"
printf "\n${GREEN}▶${NC} Preflight complete. Running terraform destroy is now safe.\n"
