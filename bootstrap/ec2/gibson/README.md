# Stage 1 on a plain cluster: one EC2 instance running k3s

This is stage 1 for an environment that does not need a managed control
plane. It builds one instance, installs k3s on it, and points the
environment's DNS at it. Staging runs here since hosted#159. Production stays
on `bootstrap/eks/gibson`.

## What it builds

| Resource | Why |
|---|---|
| VPC, one public subnet, internet gateway | The instance egresses through the gateway. There is no NAT gateway, which is about thirty dollars a month and an hourly data charge saved. |
| Security group | Port 443 to the world, because it is the product. Port 80 is closed: the chart's edge Service carries a single port, https. No port 22 and no key pair, so the operator reaches the host through SSM Session Manager. Port 6443 is closed unless the environment names an address range. |
| Instance profile | The SSM agent permissions, and pull on the setec disk repository of stage 0 (`ecr.tf`, D85). The kubelet pulls each disk through the ECR credential provider. The platform's own AWS access comes from the stage 0 keys in the bringup keyring, so a compromised pod cannot reach the durable bucket through the metadata service. |
| Elastic IP | The address outlives the instance, so replacing the instance rewrites no DNS record. |
| Instance | Amazon Linux 2023, gp3 root volume. Cloud-init installs k3s. |
| Route53 records | A wildcard and the zone apex, both pointing at the Elastic IP, inside the zone stage 0 delegated. |

## What it does not build

No load balancer. The edge is a NodePort Service on 443, which k3s allows
because stage 1 starts it with `service-node-port-range=80-32767`. kube-proxy
opens the port on the host and, with the chart's structural
`externalTrafficPolicy: Local`, does not rewrite the source address, so
Envoy's socket peer is the client. That is the plain-cluster half of the
client-IP contract (ADR-0079).

No storage class. k3s ships local-path, and the instance volume is the disk.

No secret store, no certificate, no bucket. Stage 0 owns those (ADR-0083).

## The node

Cloud-init runs `templates/node-init.sh.tftpl` once, in this order:

1. Install the host iptables tools.
2. Install the kubelet ECR credential provider, verified against its pinned
   SHA-256, at the fixed path k3s reads. The kubelet then pulls the setec
   disks from the stage 0 repository with the instance role (D85).
3. Install k3s as a systemd unit, with Traefik and the k3s load balancer both
   disabled. A reboot returns a working cluster with no operator.

The user data is gzip-compressed, because EC2 refuses user data over 16 KB.

The script writes `/var/lib/rancher/k3s/server/node-init.done` last, so its
presence means every step finished.

The node installs no sandbox runtime. The sandbox runtime of setec is the
launcher pod, and a node needs `/dev/kvm` only (ADR-0083, hosted#447).

## How a recreate drives it

`scripts/recreate-ec2.sh` applies this root in two phases, because the
Kubernetes providers cannot plan against a cluster that does not exist yet.
It is the same break `bootstrap/eks/gibson` makes.

1. **Phase 1** applies the AWS resources with a target, so no Kubernetes
   resource is in the plan.
2. The instance's own cloud-init installs k3s. k3s starts with
   flannel off, so the node has no network plugin yet. The recreate waits
   for the marker the script writes last.
3. The recreate reads the kubeconfig off the instance through SSM and opens
   an SSM port forward to the API. **The API is never published.** An
   operator with no AWS credential reaches nothing.
4. The recreate installs Cilium, the network plugin of every cluster
   (`bootstrap/cilium/`, hosted#436). It verifies the agent and proves one
   policy with a host name.
5. **Phase 2** applies Argo CD, from the module every substrate shares.
6. Stage 2 is the shared tail: ToolHive, the bringup keyring, the restore
   when one was named, and the wait for every Application.

A teardown reverses it. `scripts/teardown-ec2.sh` clears the Argo
Application finalizers first, because an Application waiting on its finalizer
blocks the destroy for as long as the API answers, which here is until the
instance dies under it.

## Running it

The bringup verbs drive this root. Run those, not Terraform by hand:

```bash
make substrate ENV=staging   # stage 0, once
make preflight ENV=staging   # prove stage 0 is live
make recreate  ENV=staging   # stage 1 and stage 2
make teardown  ENV=staging MODE=wipe|preserve
```

## Guards

`scripts/check-stage1-shape.py` and `scripts/check-no-retain.py` both read
this root. The shape guard also refuses any stage 1 root that its list does
not name, so a third root cannot arrive unguarded.

## A different instance type for drill

The drill environment accepts an instance type from the list `envs/drill.instance-types` (hosted#448). No other environment accepts one.

```sh
make recreate ENV=drill INSTANCE_TYPE=m8i.2xlarge
```

The `drill` workflow has the same value as the dispatch input `instance_type`. The scheduled run passes no value, so it uses the type of `envs/drill.tfvars`.

For a type of the `c8i`, `m8i` or `r8i` family, Terraform turns nested virtualization on. The recreate verb then fails if the node has no `/dev/kvm`.

## A second node for drill

The drill environment accepts a node count of 1 or 2 from the list `envs/drill.node-counts` (hosted#453). No other environment accepts one. The default is 1.

```sh
make recreate ENV=drill NODE_COUNT=2
```

With 2, Terraform builds a second instance of the same type. Its cloud-init (`templates/agent-init.sh.tftpl`) arms the same ceiling first, then installs k3s in agent mode and joins the server with an agent token that Terraform mints. The server takes it as `K3S_AGENT_TOKEN`, so it admits an agent and nothing else. The server token stays on the server. The agent carries the same labels as the server. The recreate waits until both nodes are Ready after the Cilium install. The reaper and the teardown find the agent by the `Environment` tag, like every resource of this root.

Neither node installs a sandbox runtime. The sandbox runtime of setec is the launcher pod, and a node needs `/dev/kvm` only (ADR-0083, hosted#447). So a sandbox can land on either node.

The `drill` workflow has the same value as the dispatch input `node_count`. The scheduled run passes no value, so it keeps one node.
