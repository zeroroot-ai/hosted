# ----------------------------------------------------------------------------
# Karpenter — node autoscaling (epic-447 #731).
#
# bootstrap-addons installs the Karpenter controller, but only when an
# interruption queue name is supplied. This file provisions that SQS queue +
# the EventBridge rules that feed it (spot ITN, rebalance, instance state
# change, scheduled health change), and the NodePool + EC2NodeClass that tell
# Karpenter what to launch. Without this, Karpenter was never installed and the
# fixed nodegroups could not absorb the full stack.
# ----------------------------------------------------------------------------

resource "aws_sqs_queue" "karpenter" {
  name                      = "${var.cluster_name}-karpenter"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
  tags                      = local.common_tags
}

data "aws_iam_policy_document" "karpenter_sqs" {
  statement {
    sid       = "AllowEventBridgeToSend"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.karpenter.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "sqs.amazonaws.com"]
    }
  }
}

resource "aws_sqs_queue_policy" "karpenter" {
  queue_url = aws_sqs_queue.karpenter.id
  policy    = data.aws_iam_policy_document.karpenter_sqs.json
}

locals {
  karpenter_event_rules = {
    spot_interruption = { source = ["aws.ec2"], detail-type = ["EC2 Spot Instance Interruption Warning"] }
    rebalance         = { source = ["aws.ec2"], detail-type = ["EC2 Instance Rebalance Recommendation"] }
    instance_state    = { source = ["aws.ec2"], detail-type = ["EC2 Instance State-change Notification"] }
    scheduled_change  = { source = ["aws.health"], detail-type = ["AWS Health Event"] }
  }
}

resource "aws_cloudwatch_event_rule" "karpenter" {
  for_each      = local.karpenter_event_rules
  name          = "${var.cluster_name}-karpenter-${each.key}"
  event_pattern = jsonencode(each.value)
  tags          = local.common_tags
}

resource "aws_cloudwatch_event_target" "karpenter" {
  for_each  = local.karpenter_event_rules
  rule      = aws_cloudwatch_event_rule.karpenter[each.key].name
  target_id = "karpenter-queue"
  arn       = aws_sqs_queue.karpenter.arn
}

# --- NodePool + EC2NodeClass (Karpenter v1 APIs) -----------------------------
# The EC2NodeClass selects subnets + SGs by the karpenter.sh/discovery tag. The
# network module tags the private subnets, but the SG that actually carries
# node connectivity (control-plane, node-to-node, and the Aurora 5432 ingress
# rule) is the EKS-managed PRIMARY cluster SG — which EKS does not tag for
# discovery. Tag it here so Karpenter launches nodes with the SAME SG the
# managed nodegroups use; without it the EC2NodeClass stays
# SecurityGroupsReady=False ("did not match any SecurityGroups") and no nodes
# are provisioned. #703.
resource "aws_ec2_tag" "karpenter_sg_discovery" {
  resource_id = module.cluster.cluster_primary_security_group_id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

resource "kubectl_manifest" "karpenter_nodeclass" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata   = { name = "default" }
    spec = {
      role                       = module.cluster.node_role_name
      amiFamily                  = "AL2023"
      amiSelectorTerms           = [{ alias = "al2023@latest" }]
      subnetSelectorTerms        = [{ tags = { "karpenter.sh/discovery" = var.cluster_name } }]
      securityGroupSelectorTerms = [{ tags = { "karpenter.sh/discovery" = var.cluster_name } }]

      # Instance-metadata access, stated explicitly rather than inherited
      # from the Karpenter default.
      #
      # httpPutResponseHopLimit 1 keeps IMDS reachable from the host and
      # unreachable from a Pod: a container's packet has already spent one
      # hop crossing the veth, so at 1 the TTL is gone before it arrives.
      # At 2 any Pod on the node can read the node role's credentials.
      #
      # This NodeClass backs the setec-metal NodePool as well as the
      # default one, so these nodes host Sandboxes running untrusted code.
      # The per-Sandbox NetworkPolicy also denies 169.254.0.0/16; these are
      # two independent controls, and neither is a substitute for the other
      # (a policy is only as good as the CNI enforcing it).
      metadataOptions = {
        httpEndpoint            = "enabled"
        httpTokens              = "required" # IMDSv2 only
        httpPutResponseHopLimit = 1
      }
    }
  })
  depends_on = [module.bootstrap_addons, aws_ec2_tag.karpenter_sg_discovery]
}

resource "kubectl_manifest" "karpenter_nodepool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = "default" }
    spec = {
      template = {
        spec = {
          nodeClassRef = { group = "karpenter.k8s.aws", kind = "EC2NodeClass", name = "default" }
          requirements = [
            { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
            { key = "karpenter.k8s.aws/instance-category", operator = "In", values = ["m", "c", "r"] },
            { key = "karpenter.k8s.aws/instance-generation", operator = "Gt", values = ["5"] },
            # No node smaller than `large`. EKS derives max-pods from the
            # instance's ENI count, so a 1-vCPU node allows EIGHT pods — and
            # SEVEN DaemonSets land on every workload node (cilium,
            # kube-proxy, ebs-csi-node, the SPIRE agent, spiffe-csi-driver,
            # setec-runtime-agent, the Velero node-agent). A `c7a.medium` is
            # therefore FULL the moment it joins, hosts no workload ever, and
            # leaves every DaemonSet rollout one pod short for good.
            #
            # Measured on staging (deploy#1746): Karpenter launched two
            # c7a.medium at 8/8 pods each, gibson-spiffe-csi-driver sat 3/4
            # Ready, and the umbrella waited on it until the recreate gave up
            # — "0/5 nodes are available: 1 Too many pods". A `large` allows
            # 29, which leaves room for the baseline and real work.
            { key = "karpenter.k8s.aws/instance-size", operator = "NotIn", values = ["nano", "micro", "small", "medium"] },
          ]
        }
      }
      limits     = { cpu = "32" }
      disruption = { consolidationPolicy = "WhenEmptyOrUnderutilized", consolidateAfter = "60s" }
    }
  })
  depends_on = [kubectl_manifest.karpenter_nodeclass]
}
