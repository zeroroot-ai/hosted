#!/usr/bin/env bats
#
# teardown-verify.bats — proves eks/gibson/scripts/eks-post-destroy-verify.sh
# FAILS CLOSED (deploy#1393).
#
# WHY THIS SUITE EXISTS
# ---------------------
# The post-destroy verifier is the only thing standing between a torn-down env
# and an ongoing bill. Its dangerous failure mode is not a red run — it is a
# GREEN run that never actually asked AWS anything: before deploy#1393, every
# query was wrapped in `2>/dev/null || true` and empty output was counted as
# zero, so expired credentials printed eight green ticks and exited 0.
#
# The contract under test, offline, by stubbing `aws` on PATH:
#   - aws exits non-zero            → script exits non-zero, class is UNKNOWN
#   - count query returns non-number → UNKNOWN, never ✓ 0
#   - genuine zeros                  → exit 0, "Teardown verified"
#   - a real leak                    → exit 1, "still billing"
#   - delete-volume fails            → exit 1 (not silently counted as deleted)
#
# Run:
#   bats tests/harness/teardown-verify.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SCRIPT="$REPO_ROOT/bootstrap/eks/gibson/scripts/eks-post-destroy-verify.sh"

setup() {
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_DIR"
  PATH="$STUB_DIR:$PATH"
  export PATH
  # The cluster under teardown. The script refuses to run without it, because
  # its volume sweep deletes (hosted#401).
  export CLUSTER_NAME="zeroroot-ai-prod"
  # No EC2 stage 1 environment unless a test builds one: the suites above
  # model an account that the teardown leaves empty. The tests at the end
  # model the account ADR-0095 made, with staging on EC2 beside the cluster.
  export EC2_ENVS_DIR="$BATS_TEST_TMPDIR/ec2-envs"
  mkdir -p "$EC2_ENVS_DIR"
}

# write_aws_stub <<'SH' ... SH — installs a fake aws for one test.
write_aws_stub() {
  cat > "$STUB_DIR/aws"
  chmod +x "$STUB_DIR/aws"
}

# A healthy post-teardown account: every count query answers 0, every ID-list
# query answers empty, the zone listing answers the retained zones.
write_healthy_aws_stub() {
  write_aws_stub <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *list-resource-record-sets*)
    # The retained baseline (deploy#1405): NS/SOA + email records + DMARC +
    # an ACM validation CNAME. None of these is stale residue.
    printf 'NS\tstaging.zeroroot.ai.\nSOA\tstaging.zeroroot.ai.\nMX\tstaging.zeroroot.ai.\nTXT\tstaging.zeroroot.ai.\nTXT\tgoogle._domainkey.staging.zeroroot.ai.\nTXT\t_dmarc.staging.zeroroot.ai.\nCNAME\t_abc123deadbeef.staging.zeroroot.ai.\n' ;;
  *list-hosted-zones*)
    printf '/hostedzone/Z0APEX00\tzeroroot.ai.\n/hostedzone/Z0STAG00\tstaging.zeroroot.ai.\n' ;;
  *"length("*)         printf '0\n' ;;
  *)                   printf '' ;;   # ID-list queries: legitimately empty
esac
exit 0
SH
}

@test "aws exits non-zero everywhere: script exits non-zero and never claims verified" {
  write_aws_stub <<'SH'
#!/usr/bin/env bash
echo "Unable to locate credentials. You can configure credentials by running \"aws configure\"." >&2
exit 255
SH
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNKNOWN"* ]]
  [[ "$output" == *"could not be established"* ]]
  [[ "$output" != *"Teardown verified"* ]]
  # The fail-open signature: green ticks for classes AWS never answered.
  [[ "$output" != *"EKS clusters: 0"* ]]
}

@test "count query returns empty output with exit 0: UNKNOWN, not zero" {
  # The exact shape a throttled/denied call produced under the old
  # `2>/dev/null || true` wrapper: empty stdout, swallowed error.
  write_aws_stub <<'SH'
#!/usr/bin/env bash
printf ''
exit 0
SH
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNKNOWN"* ]]
  [[ "$output" != *"Teardown verified"* ]]
}

@test "count query returns garbage (non-numeric): UNKNOWN, not zero" {
  write_aws_stub <<'SH'
#!/usr/bin/env bash
printf 'None\n'
exit 0
SH
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"UNKNOWN"* ]]
  [[ "$output" != *"Teardown verified"* ]]
}

@test "healthy zeros: exit 0 and Teardown verified" {
  write_healthy_aws_stub
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Teardown verified"* ]]
  [[ "$output" == *"EKS clusters: 0"* ]]
  [[ "$output" == *"Non-default VPCs: 0"* ]]
  [[ "$output" == *"Route53 zone RETAINED (by design): staging.zeroroot.ai."* ]]
  [[ "$output" == *"Stale Route53 ingress/extdns records: 0"* ]]
  # deploy#1404 coverage expansion: the new classes are enumerated.
  [[ "$output" == *"EKS nodegroups: 0"* ]]
  [[ "$output" == *"ENIs (available): 0"* ]]
  [[ "$output" == *"EBS snapshots: 0"* ]]
  [[ "$output" == *"ElastiCache replication groups: 0"* ]]
  [[ "$output" == *"EFS filesystems: 0"* ]]
  [[ "$output" == *"ELBv2 target groups: 0"* ]]
  [[ "$output" == *"Secrets Manager pending-deletion: 0"* ]]
  [[ "$output" == *"Tagged survivors"* ]]
}

@test "a real leak: exit 1 with 'still billing'" {
  write_aws_stub <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *list-hosted-zones*)          printf 'zeroroot.ai.\n' ;;
  *describe-nat-gateways*)      printf '2\n' ;;
  *"length("*)                  printf '0\n' ;;
  *)                            printf '' ;;
esac
exit 0
SH
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NAT gateways: 2 remaining"* ]]
  [[ "$output" == *"still billing"* ]]
  [[ "$output" != *"Teardown verified"* ]]
}

@test "partial failure: one denied query fails the run even when the rest are zero" {
  write_aws_stub <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *describe-db-clusters*)
    echo "An error occurred (AccessDenied) when calling the DescribeDBClusters operation" >&2
    exit 254 ;;
  *list-hosted-zones*) printf 'zeroroot.ai.\n' ;;
  *"length("*)         printf '0\n' ;;
  *)                   printf '' ;;
esac
exit 0
SH
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"RDS clusters: UNKNOWN"* ]]
  [[ "$output" == *"could not be established"* ]]
  [[ "$output" != *"Teardown verified"* ]]
}

@test "failed delete-volume is a failure, not counted as deleted" {
  write_aws_stub <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *delete-volume*)
    echo "An error occurred (VolumeInUse) when calling the DeleteVolume operation" >&2
    exit 254 ;;
  *describe-volumes*Name=tag-key*status=available*|*describe-volumes*status,Values=available*)
    printf 'vol-0deadbeef\n' ;;
  *list-hosted-zones*) printf 'zeroroot.ai.\n' ;;
  *"length("*)         printf '0\n' ;;
  *)                   printf '' ;;
esac
exit 0
SH
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CSI-orphan delete vol-0deadbeef"* ]]
  [[ "$output" == *"deleted 0 orphaned volume(s)"* ]]
  [[ "$output" != *"Teardown verified"* ]]
}

@test "a stopped instance is a leak: no tag exempts it (deploy#1743)" {
  # The teardown tag allowlist is gone. A hand-made runner that a teardown
  # left behind bills, and the verify says so with its count.
  write_aws_stub <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *describe-instances*"length("*) printf '1\n' ;;
  *list-hosted-zones*)            printf 'zeroroot.ai.\n' ;;
  *"length("*)                    printf '0\n' ;;
  *)                              printf '' ;;
esac
exit 0
SH
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"EC2 instances: 1 remaining"* ]]
  [[ "$output" == *"still billing"* ]]
  [[ "$output" != *"RETAINED (teardown"* ]]
}

@test "EC2 instance count query failure: UNKNOWN, not zero" {
  write_aws_stub <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *describe-instances*)
    echo "An error occurred (RequestLimitExceeded)" >&2
    exit 254 ;;
  *list-hosted-zones*)  printf 'zeroroot.ai.\n' ;;
  *"length("*)          printf '0\n' ;;
  *)                    printf '' ;;
esac
exit 0
SH
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"EC2 instances: UNKNOWN"* ]]
  [[ "$output" != *"EC2 instances: 0"* ]]
  [[ "$output" != *"Teardown verified"* ]]
}

# ---------------------------------------------------------------------------
# deploy#1404 — coverage expansion + ADR-0070 tagging-API sweep
# ---------------------------------------------------------------------------

@test "surviving nodegroup on a surviving cluster: exit 1" {
  write_aws_stub <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *list-nodegroups*"length("*) printf '1\n' ;;
  *list-clusters*"length("*)   printf '1\n' ;;
  *list-clusters*)             printf 'zeroroot-ai-staging\n' ;;
  *list-hosted-zones*)         printf 'zeroroot.ai.\n' ;;
  *"length("*)                 printf '0\n' ;;
  *)                           printf '' ;;
esac
exit 0
SH
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"EKS nodegroups: 1 remaining"* ]]
  [[ "$output" == *"still billing"* ]]
}

@test "secrets-manager pending-deletion residue: exit 1" {
  write_aws_stub <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *list-secrets*)      printf '2\n' ;;
  *list-hosted-zones*) printf 'zeroroot.ai.\n' ;;
  *"length("*)         printf '0\n' ;;
  *)                   printf '' ;;
esac
exit 0
SH
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Secrets Manager pending-deletion: 2 remaining"* ]]
}

@test "tagging sweep: a survivor outside retained-by-design services fails with its ARN" {
  write_aws_stub <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *get-resources*)
    # one retained-by-design service + one genuine survivor
    printf 'arn:aws:s3:::zeroroot-ai-staging-tfstate\tarn:aws:logs:us-east-1:000000000000:log-group:/aws/eks/zeroroot-ai-staging/cluster\n' ;;
  *list-hosted-zones*) printf 'zeroroot.ai.\n' ;;
  *"length("*)         printf '0\n' ;;
  *)                   printf '' ;;
esac
exit 0
SH
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tagged survivor: arn:aws:logs:"* ]]
  [[ "$output" != *"tagged survivor: arn:aws:s3:"* ]]
  [[ "$output" == *"Tagged survivors (outside retained-by-design services): 1 remaining"* ]]
}

@test "tagging sweep: the public web surfaces are retained by design, a tagged instance is not (ADR-0077, deploy#1743)" {
  # bootstrap/eks/public-site's distribution and lead path outlive every
  # teardown. They pass by service and by name, never by a tag. The survivor
  # here is Karpenter's SQS interruption queue: a class NO explicit probe
  # covers, so the backstop is the only thing that sees it — which is the
  # backstop's whole job. (A leaked EC2 instance is asserted by its own probe,
  # two tests up; since 2026-09-14 the backstop treats an instance ARN as
  # index lag once that probe has verified the class gone.)
  write_aws_stub <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *get-resources*)
    printf 'arn:aws:cloudfront::000000000000:distribution/EXAMPLEDIST01\tarn:aws:lambda:us-east-1:000000000000:function:www-contact-sales\tarn:aws:sns:us-east-1:000000000000:www-contact-sales-leads\tarn:aws:logs:us-east-1:000000000000:log-group:/aws/lambda/www-contact-sales\tarn:aws:apigateway:us-east-1::/apis/919dwx1nlk\tarn:aws:sqs:us-east-1:000000000000:zeroroot-ai-staging-karpenter\n' ;;
  *list-hosted-zones*) printf 'zeroroot.ai.\n' ;;
  *"length("*)         printf '0\n' ;;
  *)                   printf '' ;;
esac
exit 0
SH
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tagged survivor: arn:aws:sqs:us-east-1:000000000000:zeroroot-ai-staging-karpenter"* ]]
  [[ "$output" != *"tagged survivor: arn:aws:cloudfront"* ]]
  [[ "$output" != *"tagged survivor: arn:aws:lambda"* ]]
  [[ "$output" != *"tagged survivor: arn:aws:sns"* ]]
  [[ "$output" != *"tagged survivor: arn:aws:logs"* ]]
  [[ "$output" != *"tagged survivor: arn:aws:apigateway"* ]]
  [[ "$output" == *"Tagged survivors (outside retained-by-design services): 1 remaining"* ]]
}

# ---------------------------------------------------------------------------
# The Tagging API index is eventually consistent (2026-09-14). After a clean
# teardown it still returned 55 ARNs for resources the explicit probes had
# just proved gone — snapshots and a volume deleted minutes earlier, pods and
# instant-fleet records of a cluster deleted days earlier. A backstop that
# reports those teaches the reader to ignore it, so an ARN whose class a probe
# verified clean is index lag; an ARN whose class NO probe covers still fails.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# The VPC-scoped EC2 classes (2026-09-14).
#
# Eight ENIs and a security group were reported as survivors minutes after
# their VPC was destroyed. `describe-network-interfaces` answered
# InvalidNetworkInterfaceID.NotFound for every one of them, and
# `describe-security-groups` answered InvalidGroup.NotFound: pure Tagging API
# index lag. Nothing can outlive the VPC it lives in, so zero non-default VPCs
# is the authority for all of them, and reporting them teaches the reader to
# ignore the backstop.
# ---------------------------------------------------------------------------
@test "tagging sweep: ENIs and security groups go with their VPC, so their stale ARNs are lag" {
  write_aws_stub <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *get-resources*)
    printf 'arn:aws:ec2:us-east-1:000000000000:network-interface/eni-0123456789abcdef0\tarn:aws:ec2:us-east-1:000000000000:security-group/sg-0123456789abcdef0\tarn:aws:ec2:us-east-1:000000000000:subnet/subnet-0dead\tarn:aws:ec2:us-east-1:000000000000:route-table/rtb-0dead\n' ;;
  *list-hosted-zones*) printf 'zeroroot.ai.\n' ;;
  *"length("*)         printf '0\n' ;;
  *)                   printf '' ;;
esac
exit 0
SH
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"tagged survivor"* ]]
  [[ "$output" == *"4 stale index entries skipped"* ]]
  [[ "$output" == *"Teardown verified"* ]]
}

# FAILING FIXTURE: the same ARNs when a VPC is still standing. The skip is the
# probe's authority, never the ARN's shape, so an unproved class is a leak.
@test "FAILING FIXTURE: an ENI is a leak while a non-default VPC survives" {
  write_aws_stub <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *get-resources*)
    printf 'arn:aws:ec2:us-east-1:000000000000:network-interface/eni-0123456789abcdef0\n' ;;
  *list-hosted-zones*) printf 'zeroroot.ai.\n' ;;
  *describe-vpcs*)     printf '1\n' ;;
  *"length("*)         printf '0\n' ;;
  *)                   printf '' ;;
esac
exit 0
SH
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"tagged survivor: arn:aws:ec2:us-east-1:000000000000:network-interface/eni-0123456789abcdef0"* ]]
}

@test "tagging sweep: an ARN whose class a probe verified clean is index lag, not a leak" {
  write_aws_stub <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *get-resources*)
    printf 'arn:aws:ec2:us-east-1:000000000000:snapshot/snap-0dead\tarn:aws:ec2:us-east-1:000000000000:instance/i-0dead\tarn:aws:ec2:us-east-1:000000000000:volume/vol-0dead\tarn:aws:ec2:us-east-1:000000000000:fleet/fleet-0dead\tarn:aws:eks:us-east-1:000000000000:pod/zeroroot-ai-staging/gibson/gibson-openbao-0/1189af9f\n' ;;
  *list-hosted-zones*) printf 'zeroroot.ai.\n' ;;
  *"length("*)         printf '0\n' ;;
  *)                   printf '' ;;
esac
exit 0
SH
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"tagged survivor"* ]]
  [[ "$output" == *"5 stale index entries skipped"* ]]
  [[ "$output" == *"Tagged survivors (outside retained-by-design services): 0"* ]]
  [[ "$output" == *"Teardown verified"* ]]
}

@test "FAILING FIXTURE: the same ARN is a leak when its probe did NOT verify the class" {
  # Identical sweep, but the EC2-instance probe answers 2. The class never
  # reaches the probed-clean list, so nothing is skipped on its account and
  # the run fails twice over: once on the probe, once on the backstop.
  write_aws_stub <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *get-resources*)
    printf 'arn:aws:ec2:us-east-1:000000000000:instance/i-0dead\n' ;;
  *list-hosted-zones*) printf 'zeroroot.ai.\n' ;;
  *describe-instances*) printf '2\n' ;;
  *"length("*)         printf '0\n' ;;
  *)                   printf '' ;;
esac
exit 0
SH
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"EC2 instances: 2 remaining"* ]]
  [[ "$output" == *"tagged survivor: arn:aws:ec2:us-east-1:000000000000:instance/i-0dead"* ]]
  [[ "$output" != *"Teardown verified"* ]]
}

@test "a manual RDS cluster snapshot outlives its cluster and is a leak (ADR-0083)" {
  write_aws_stub <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *describe-db-cluster-snapshots*) printf '2\n' ;;
  *list-hosted-zones*) printf 'zeroroot.ai.\n' ;;
  *"length("*)         printf '0\n' ;;
  *)                   printf '' ;;
esac
exit 0
SH
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"RDS cluster snapshots (manual): 2 remaining"* ]]
  [[ "$output" != *"Teardown verified"* ]]
}

@test "tagging sweep: a leaked lambda outside the www-* lead path is a survivor" {
  write_aws_stub <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *get-resources*)
    printf 'arn:aws:lambda:us-east-1:000000000000:function:gibson-leftover\n' ;;
  *list-hosted-zones*) printf 'zeroroot.ai.\n' ;;
  *"length("*)         printf '0\n' ;;
  *)                   printf '' ;;
esac
exit 0
SH
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tagged survivor: arn:aws:lambda:us-east-1:000000000000:function:gibson-leftover"* ]]
}

@test "tagging sweep query failure: UNKNOWN, run fails" {
  write_aws_stub <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *get-resources*)
    echo "An error occurred (AccessDeniedException) when calling the GetResources operation" >&2
    exit 254 ;;
  *list-hosted-zones*) printf 'zeroroot.ai.\n' ;;
  *"length("*)         printf '0\n' ;;
  *)                   printf '' ;;
esac
exit 0
SH
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Tagging-API sweep"* ]]
  [[ "$output" == *"could not be established"* ]]
  [[ "$output" != *"Teardown verified"* ]]
}

# ---------------------------------------------------------------------------
# deploy#1405 — post-teardown Route53 record baseline
# ---------------------------------------------------------------------------

@test "stale extdns TXT + ingress A record after teardown: exit 1 with both named" {
  write_aws_stub <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *list-resource-record-sets*)
    printf 'NS\tstaging.zeroroot.ai.\nSOA\tstaging.zeroroot.ai.\nA\tapp.staging.zeroroot.ai.\nTXT\textdns-app.staging.zeroroot.ai.\n' ;;
  *list-hosted-zones*)
    printf '/hostedzone/Z0STAG00\tstaging.zeroroot.ai.\n' ;;
  *"length("*) printf '0\n' ;;
  *)           printf '' ;;
esac
exit 0
SH
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale ingress record: A app.staging.zeroroot.ai."* ]]
  [[ "$output" == *"stale external-dns ownership TXT: extdns-app.staging.zeroroot.ai."* ]]
  [[ "$output" == *"Stale Route53 ingress/extdns records: 2 remaining"* ]]
  [[ "$output" != *"Teardown verified"* ]]
}

# ---------------------------------------------------------------------------
# Ingress records are classified by their TARGET (2026-09-11). The apex zone
# carries live CloudFront aliases for the marketing site and the docs site
# (ADR-0077); a name-only rule read all six as cluster residue after a clean
# staging teardown, so the verifier failed every teardown for as long as the
# marketing site existed. The pair below is the fix and its failing fixture:
# a CloudFront target is retained, an ELB target at the SAME name is not.
# ---------------------------------------------------------------------------

@test "apex CloudFront aliases are the public web surfaces, not cluster residue (ADR-0077)" {
  write_aws_stub <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *list-resource-record-sets*)
    printf 'NS\tzeroroot.ai.\nSOA\tzeroroot.ai.\nA\tzeroroot.ai.\td28dtd0crg3dx7.cloudfront.net.\nAAAA\tzeroroot.ai.\td28dtd0crg3dx7.cloudfront.net.\nA\twww.zeroroot.ai.\td28dtd0crg3dx7.cloudfront.net.\nAAAA\twww.zeroroot.ai.\td28dtd0crg3dx7.cloudfront.net.\nA\tdocs.zeroroot.ai.\td16oszcmi39909.cloudfront.net.\nAAAA\tdocs.zeroroot.ai.\td16oszcmi39909.cloudfront.net.\n' ;;
  *list-hosted-zones*)
    printf '/hostedzone/Z0APEX00\tzeroroot.ai.\n' ;;
  *"length("*) printf '0\n' ;;
  *)           printf '' ;;
esac
exit 0
SH
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"public web surface RETAINED (by design, ADR-0077): A zeroroot.ai."* ]]
  [[ "$output" == *"public web surface RETAINED (by design, ADR-0077): AAAA docs.zeroroot.ai."* ]]
  [[ "$output" == *"Stale Route53 ingress/extdns records: 0"* ]]
  [[ "$output" != *"stale ingress record"* ]]
  [[ "$output" == *"Teardown verified"* ]]
}

@test "FAILING FIXTURE: an ELB alias at those same names is cluster residue" {
  write_aws_stub <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *list-resource-record-sets*)
    printf 'NS\tzeroroot.ai.\nSOA\tzeroroot.ai.\nA\tzeroroot.ai.\tk8s-gibson-gibsonen-6aa095335b-67c73a33d5bff395.elb.us-east-1.amazonaws.com.\nAAAA\twww.zeroroot.ai.\td28dtd0crg3dx7.cloudfront.net.\n' ;;
  *list-hosted-zones*)
    printf '/hostedzone/Z0APEX00\tzeroroot.ai.\n' ;;
  *"length("*) printf '0\n' ;;
  *)           printf '' ;;
esac
exit 0
SH
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale ingress record: A zeroroot.ai."* ]]
  [[ "$output" == *"public web surface RETAINED (by design, ADR-0077): AAAA www.zeroroot.ai."* ]]
  [[ "$output" == *"Stale Route53 ingress/extdns records: 1 remaining"* ]]
  [[ "$output" != *"Teardown verified"* ]]
}

@test "FAILING FIXTURE: a plain (non-alias) A record at an ingress name is still residue" {
  write_aws_stub <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *list-resource-record-sets*)
    # --output text renders a null AliasTarget.DNSName as the string None.
    printf 'NS\tstaging.zeroroot.ai.\nSOA\tstaging.zeroroot.ai.\nA\tapi.staging.zeroroot.ai.\tNone\n' ;;
  *list-hosted-zones*)
    printf '/hostedzone/Z0STAG00\tstaging.zeroroot.ai.\n' ;;
  *"length("*) printf '0\n' ;;
  *)           printf '' ;;
esac
exit 0
SH
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale ingress record: A api.staging.zeroroot.ai."* ]]
  [[ "$output" != *"Teardown verified"* ]]
}

@test "record-set listing failure: UNKNOWN, run fails" {
  write_aws_stub <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *list-resource-record-sets*)
    echo "An error occurred (AccessDenied) when calling the ListResourceRecordSets operation" >&2
    exit 254 ;;
  *list-hosted-zones*)
    printf '/hostedzone/Z0STAG00\tstaging.zeroroot.ai.\n' ;;
  *"length("*) printf '0\n' ;;
  *)           printf '' ;;
esac
exit 0
SH
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Route53 records (staging.zeroroot.ai.): UNKNOWN"* ]]
  [[ "$output" != *"Teardown verified"* ]]
}

# ---------------------------------------------------------------------------
# hosted#401 — staging on EC2 lives in the same account (ADR-0095).
# ---------------------------------------------------------------------------

# An account that holds the staging EC2 environment and nothing else. Every
# query the script narrows to the kept workspace answers with the same
# resource, so total minus kept is zero. EXTRA_INSTANCES adds leftovers of the
# destroyed cluster to the unfiltered instance count.
write_staging_cotenant_stub() {
  printf 'environment    = "staging"\nworkspace_name = "zeroroot-ai-staging"\n' > "$EC2_ENVS_DIR/staging.tfvars"
  write_aws_stub <<'SH'
#!/usr/bin/env bash
args="$*"
log="${AWS_CALL_LOG:-/dev/null}"
printf '%s\n' "$args" >> "$log"
case "$args" in
  *delete-volume*) exit 0 ;;
  *describe-volumes*tag-key*kubernetes.io/cluster/zeroroot-ai-prod*) printf 'vol-prod1\n' ;;
  *describe-volumes*tag-key*) printf 'vol-staging1\n' ;;
  *describe-instances*InstanceId*) printf 'i-staging1\n' ;;
  *describe-instances*tag:Workspace*) printf '1\n' ;;
  *describe-instances*) printf '%s\n' "$((1 + ${EXTRA_INSTANCES:-0}))" ;;
  *describe-volumes*attachment.instance-id*i-staging1*) printf '1\n' ;;
  *describe-volumes*"length("*) printf '1\n' ;;
  *describe-addresses*) printf '1\n' ;;
  *describe-vpcs*) printf '1\n' ;;
  *get-resources*)
    printf 'arn:aws:ec2:us-east-1:111111111111:instance/i-staging1\tarn:aws:ssm:us-east-1:111111111111:parameter/staging-kubeconfig\n' ;;
  *list-resource-record-sets*) printf 'NS\tstaging.zeroroot.ai.\nSOA\tstaging.zeroroot.ai.\n' ;;
  *list-hosted-zones*) printf '/hostedzone/Z0STAG00\tstaging.zeroroot.ai.\n' ;;
  *"length("*) printf '0\n' ;;
  *) printf '' ;;
esac
exit 0
SH
}

@test "FAILING FIXTURE: the sweep deletes the destroyed cluster's volume and no other cluster's (hosted#401)" {
  write_staging_cotenant_stub
  export AWS_CALL_LOG="$BATS_TEST_TMPDIR/aws.log"
  run bash "$SCRIPT"
  grep -q 'delete-volume --volume-id vol-prod1' "$AWS_CALL_LOG"
  ! grep -q 'vol-staging1' "$AWS_CALL_LOG" || { echo "the sweep touched a volume of another cluster"; cat "$AWS_CALL_LOG"; false; }
  # The old sweep listed by a wildcard tag key. Prove this one never asks for it.
  run grep -c 'kubernetes.io/cluster/\*\|ebs.csi.aws.com/cluster' "$AWS_CALL_LOG"
  [ "$output" = "0" ]
}

@test "FAILING FIXTURE: an EKS teardown verifies clean while staging runs on EC2 (hosted#401, ADR-0095)" {
  write_staging_cotenant_stub
  run bash "$SCRIPT"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"EC2 instances: 1 kept by design"* ]]
  [[ "$output" == *"EBS volumes: 1 kept by design"* ]]
  [[ "$output" == *"Elastic IPs: 1 kept by design"* ]]
  [[ "$output" == *"Non-default VPCs: 1 kept by design"* ]]
  [[ "$output" == *"2 tagged resource(s) kept by design"* ]]
  [[ "$output" == *"Teardown verified"* ]]
}

@test "a leftover instance of the destroyed cluster still fails beside the kept one (hosted#401)" {
  write_staging_cotenant_stub
  EXTRA_INSTANCES=1 run bash "$SCRIPT"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"EC2 instances: 1 remaining"* ]]
}

@test "an instance with no kept workspace is a leak even when an EC2 environment exists (hosted#401)" {
  # The kept set is a workspace Terraform stamped, never "any EC2 instance".
  write_staging_cotenant_stub
  sed -i 's/zeroroot-ai-staging/zeroroot-ai-other/' "$EC2_ENVS_DIR/staging.tfvars"
  sed -i 's/\*describe-instances\*tag:Workspace\*) printf .1\\n. ;;/*describe-instances*tag:Workspace*) printf "0\\n" ;;/' "$STUB_DIR/aws"
  run bash "$SCRIPT"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"EC2 instances: 1 remaining"* ]]
}

@test "no CLUSTER_NAME: the script refuses to run and deletes nothing (hosted#401)" {
  write_staging_cotenant_stub
  export AWS_CALL_LOG="$BATS_TEST_TMPDIR/aws.log"; : > "$AWS_CALL_LOG"
  unset CLUSTER_NAME
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CLUSTER_NAME is required"* ]]
  [ ! -s "$AWS_CALL_LOG" ]
}
