# STAGING. The kubernetes-goat target, beside the staging platform node and
# never on it.
#
# This root joins the staging VPC and subnet, so Gibson's agents on the platform
# node can reach the target privately.

environment    = "staging"
workspace_name = "zeroroot-ai-staging"
target_name    = "zeroroot-ai-staging-goat"
cost_center    = "platform-staging"
aws_region     = "us-east-1"
aws_account_id = "447184491447"

# The staging platform this target joins. The VPC, the subnet and the platform
# node's security group (the only source allowed to reach the target's API on
# 6443) are found by the Name tags of bootstrap/ec2/gibson. This root creates
# none of them.
platform_cluster_name = "zeroroot-ai-staging"

# The fixed private address of the node. The registered Target names
# https://10.60.0.66:6443, and a recreate must keep that address, or the
# Target points at nothing (gibson#498). It must sit inside the subnet
# zeroroot-ai-staging-public (10.60.0.0/24), and the platform node must not
# hold it.
private_ip = "10.60.0.66"

# 2 vCPU and 4 GB. The goat's twelve workloads take 50 to 100 MiB each, so this
# leaves room for k3s itself and the image layers.
instance_type  = "t3.medium"
root_volume_gb = 30

# The repository the fix loop reconciles from. An agent opens a merge request,
# it merges, and the next run of the timer applies it.
goat_repo_url = "https://gitlab.com/zero-root/kubernetes-goat.git"
goat_repo_ref = "main"

# The SecureString holding "username:token" for the project deploy token with
# read_repository scope. THE OPERATOR CREATES IT BY HAND (see README.md). No
# token value is ever written here.
deploy_token_parameter_name = "/zeroroot-ai/staging/goat/gitlab-deploy-token"

reconcile_interval = "2min"
