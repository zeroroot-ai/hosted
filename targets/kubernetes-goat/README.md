# The kubernetes-goat target

One EC2 instance in the staging VPC, running k3s, carrying
[kubernetes-goat](https://gitlab.com/zero-root/kubernetes-goat). It is the
cluster Gibson's agents assess and exploit.

It is a **target**, not part of the platform. It runs no platform component, it
reconciles no Argo tree and it holds nothing anyone needs after it dies. That is
why it lives here and not under `bootstrap/`: a root under `bootstrap/` with a
`backend.tf` and an `envs/` directory is a stage 1 root by shape, and
`scripts/check-stage1-shape.py` would read it as one. This is not one.

## Why it is a separate instance from the platform

Staging is a single k3s node. It carries OpenBao, Zitadel and the tenant data
plane. The goat is deliberately vulnerable, and several of its scenarios escape
the container to the host: `system-monitor`, `hidden-in-layers` and the
privileged `health-check` pod all exist to be broken out of.

A container escape on a shared node reaches OpenBao's memory, the Zitadel
database and every tenant secret on that host. The separate instance is the
whole point. There is no node selector, no namespace boundary and no admission
policy that makes sharing the node acceptable, because the escape is the
exercise.

The two machines share one VPC and one subnet, and nothing else:

| | Platform node | Goat target |
|---|---|---|
| Root | `bootstrap/ec2/gibson` | `targets/kubernetes-goat` |
| State key | `tfstate/ec2-gibson/terraform.tfstate` | `tfstate/targets/kubernetes-goat/terraform.tfstate` |
| Inbound from the internet | 443, the edge | **none, on any port** |
| Inbound from the other | — | 6443, by security-group reference |
| Instance role | SSM only | SSM only |
| `/dev/kvm` for setec sandboxes | yes (ADR-0083) | **no**, on purpose |
| Elastic IP, DNS, certificate | yes | none |

## What it builds

| Resource | Why |
|---|---|
| Security group | One ingress rule: 6443 from the platform node's security group, by reference and never an address range. Nothing from the internet, on any port. |
| Security group rules | The one ingress above, and egress everywhere so the node pulls k3s, helm, the scenario images and the repository. |
| IAM role and instance profile | `AmazonSSMManagedInstanceCore` and nothing else. This instance can do nothing in AWS. |
| Instance | `t3.medium`, Amazon Linux 2023, a 30 GB encrypted gp3 root volume, IMDSv2 required with a hop limit of 1. |

It builds **no** VPC, subnet, internet gateway, route table, Elastic IP, DNS
record, certificate, bucket, Argo Application or Kubernetes resource. It joins
the existing staging network by name: the VPC, the public subnet and the node
security group carry the Name tags that `bootstrap/ec2/gibson` derives from
`platform_cluster_name`. No id is pinned, so a recreate of staging needs no
change here.

## The fix loop

An agent finds a problem, opens a merge request against the goat repository, it
merges, and a rescan must see the cluster actually changed. So the node
reconciles from the repository rather than from a one-time copy.

`goat-reconcile.timer` runs `/usr/local/bin/goat-reconcile` every two minutes.
Each run:

1. Reads the deploy token from SSM Parameter Store. Fresh every run, never
   written to disk.
2. Fetches the tracked branch and hard-resets to it. It logs the old and the new
   commit, and the subject line of every commit in between.
3. Reads the manifest paths and the chart out of the goat's own
   `setup-kubernetes-goat.sh`, dropping commented lines.
4. Applies them with `kubectl apply` and `helm upgrade --install`.
5. Logs the revision it converged on and the pod count.

### Why it does not run `setup-kubernetes-goat.sh`

The script is not idempotent and does not fail closed. It installs the chart
with `helm install`, which fails on every run after the first with `cannot
re-use a released name`, and it carries no `set -e`, so a run would report
success with half of the scenarios unapplied.

So the reconcile reads the **what** out of that script — the manifest paths and
the chart — and owns the **how**. The goat repository stays the single source of
truth for which scenarios exist, so a merge request that adds one needs no
change here. `kubectl apply` is the same verb the script uses, so running the
script by hand afterwards fights nothing.

### Reading the log

```bash
# the structured record, newest last
aws ssm start-session --target "$(terraform output -raw instance_id)" \
  --profile zeroroot-prod --region us-east-1
sudo journalctl -u goat-reconcile.service --since '-30min'
sudo tail -40 /var/log/goat-reconcile.log
```

A pull that followed a merge reads as one line:

```
2026-10-01T14:22:06Z goat-reconcile: PULLED main: 3f2a1c9 -> 8d41e07
    8d41e07 fix(health-check): drop the privileged flag
```

## How to reach it

There is no public address, no DNS record and no open port. Two ways in, both
through SSM, both needing an AWS credential for account `447184491447`.

```bash
export AWS_PROFILE=zeroroot-prod
ID="$(terraform output -raw instance_id)"

# a shell on the host
aws ssm start-session --target "$ID" --region us-east-1

# the Kubernetes API, forwarded to a local port
aws ssm start-session --target "$ID" --region us-east-1 \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["6443"],"localPortNumber":["7443"]}'
```

The kubeconfig is on the host at
`/var/lib/rancher/k3s/server/kubeconfig-external.yaml`, already naming the
instance's private address. Rewrite the server to `https://127.0.0.1:7443` to
use it through the forward above.

Gibson's agents on the platform node need no forward. They dial
`https://<private_ip>:6443` directly, which is the one thing the security group
allows.

## The manual steps, which Terraform does not do

Two, both by hand, both before the first recreate that applies this root. Terraform never holds the token.

**1. The GitLab deploy token.** In
`https://gitlab.com/zero-root/kubernetes-goat` → Settings → Repository → Deploy
tokens, create one with the **`read_repository` scope and nothing else**. No
expiry is needed for a demo target. GitLab shows the username and the token
once. Keep both.

**2. The SSM parameter.** The value is the username, a colon, then the token.

```bash
aws ssm put-parameter \
  --profile zeroroot-prod --region us-east-1 \
  --name /zeroroot-ai/staging/goat/gitlab-deploy-token \
  --type SecureString \
  --value 'gitlab+deploy-token-123456:glpat-xxxxxxxxxxxxxxxxxxxx'
```

`--type SecureString` with no `--key-id` uses the AWS managed `alias/aws/ssm`
key. That is deliberate and load-bearing: the key policy of that key grants
`kms:Decrypt` to any principal in the account calling through SSM, so the
instance decrypts the parameter with `AmazonSSMManagedInstanceCore` alone and
needs no inline KMS policy. **A customer managed key breaks the fix loop**,
because the role carries no `kms:Decrypt`.

The reconcile calls `ssm get-parameters`, the **plural** form.
`AmazonSSMManagedInstanceCore` grants `ssm:GetParameters` and not
`ssm:GetParameter`, so the singular call fails with `AccessDenied` on a role
that is correct.

Neither step is in Terraform, and the parameter is not read by a data source
either: a data source would copy the decrypted token into the state file, and it
would fail every `plan` until the parameter exists.

## Running it

`make recreate ENV=staging` applies this root. `scripts/recreate-ec2.sh` calls
`targets_apply` (`scripts/lib/targets.sh`) after stage 1 phase 1 and before Argo
CD, because phase 1 makes the VPC, the subnet and the node security group that
this root finds by their Name tags. The platform node and the goat node boot
side by side. The recreate stops before the apply when the SSM parameter of step
2 above does not exist.

`make teardown ENV=staging` destroys this root first, because stage 1 cannot
delete its subnet and its security group while the target is in them. A
`make recreate` brings it back with no other step. The environments that have no
`envs/<env>.tfvars` here (drill, prod) get no target.

To plan this root alone, for example to read a change before a recreate, run
these commands.

```bash
export AWS_PROFILE=zeroroot-prod
cd targets/kubernetes-goat

terraform init -reconfigure -input=false \
  -backend-config="key=tfstate/targets/kubernetes-goat/terraform.tfstate" \
  -backend-config="bucket=zeroroot-ai-staging-durable-447184491447" \
  -backend-config="region=us-east-1" \
  -backend-config="use_lockfile=true"

terraform plan -var-file=envs/staging.tfvars
```

The state key is `tfstate/targets/kubernetes-goat/terraform.tfstate`. It shares the staging
durable bucket with `bootstrap/ec2/gibson` and nothing else. A shared key would
let a goat apply destroy the platform.

## After an apply

The node writes `/var/lib/rancher/k3s/server/node-init.done` last, so its
presence means k3s is up, the timer is running and the first reconcile has run.
Cloud-init's own record is `/var/log/node-init.log`.

```bash
sudo test -f /var/lib/rancher/k3s/server/node-init.done && echo ready
sudo systemctl list-timers goat-reconcile.timer
sudo kubectl get pods --all-namespaces
```

Twelve workloads and one chart. A pod that stays `Pending` on a `t3.medium` is
the signal to raise `instance_type`, which is a variable for that reason.
