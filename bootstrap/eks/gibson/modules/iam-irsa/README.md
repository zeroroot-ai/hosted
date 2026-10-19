# iam-irsa module

Provisions the three controller IRSA roles that stage 1 keeps (ADR-0083).
Each role trusts one exact `system:serviceaccount:<ns>:<sa>` subject on the
cluster OIDC provider, and carries the controller permission boundary.

## Roles

| Key | Namespace | SA | Policy |
|---|---|---|---|
| `aws_lb_controller` | kube-system | aws-load-balancer-controller | `policies/aws-lb-controller.json` (upstream) |
| `karpenter` | kube-system | karpenter | `policies/karpenter.json` (upstream, `CLUSTER_NAME` templated) |
| `ebs_csi` | kube-system | ebs-csi-controller-sa | AWS managed `AmazonEBSCSIDriverPolicy` |

No workload role exists here. A platform workload that needs the object
store uses the durable bucket credential from the bringup keyring (stage 0,
`eks/gibson-bootstrap`). A module for a further cloud has the same shape:
the identities for that cloud's load balancer, storage and autoscaler
controllers, bound to the same three ServiceAccounts, and nothing else.
