# Cilium, the network plugin of every cluster

Cilium runs on every cluster (ADR-0083, hosted#436). The chart renders `CiliumNetworkPolicy` for egress by host name, so each node must enforce that policy type.

## Files

| File | Content |
|---|---|
| `VERSION` | The one pin of the Cilium version. `scripts/check-cilium-pin.py` fails when a second pin in the repo differs. |
| `values.yaml` | The values that each substrate uses. |
| `values-<flavor>.yaml` | The values of one substrate. A substrate with no file uses the shared values only. |

## How a substrate installs it

`scripts/lib/cilium.sh` holds four functions. Each bringup calls three of them after the API answers and before the first pod must start.

1. `cilium_install <flavor>` installs the chart at the pinned version.
2. `cilium_verify` fails when the `CiliumNetworkPolicy` CRD is absent, when an agent is not ready, or when the DNS proxy answers a denied lookup with anything but NXDOMAIN (`dnsProxy.dnsRejectResponseCode: nameError`).
3. `cilium_prove_fqdn_policy` applies one policy with a host name. It proves one permitted connection and one refused connection.

| Substrate | Where |
|---|---|
| kind (the CI clusters) | `scripts/recreate-kind.sh`. The cluster starts with `disableDefaultCNI`. |
| k3d | `scripts/cluster-k3d.sh`. k3s starts with flannel off. |
| EKS (prod) | `bootstrap/eks/gibson/modules/cluster/main.tf`. A `helm_release` installs Cilium in ENI mode after the control plane and before the node groups. The cluster has no `vpc-cni` add-on. `scripts/recreate-aws.sh` verifies the agent and proves the policy. |
| EC2 with k3s (staging, drill) | `bootstrap/ec2/gibson/templates/node-init.sh.tftpl` starts k3s with flannel off. `scripts/recreate-ec2.sh` installs Cilium through the SSM forward, before CoreDNS gets its record and before Argo CD. |

## To change the version

1. Change `VERSION`.
2. Run `make check-cilium`.
3. Merge. The exit tests on `main` prove the new version on a kind cluster.
