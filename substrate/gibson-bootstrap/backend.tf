# ----------------------------------------------------------------------------
# State of stage 0 itself: LOCAL, outside the checkout.
#
# The durable bucket cannot hold the state of the workspace that creates it.
# So stage 0 keeps a local state file, and substrate.sh puts it next to the
# keyring under SUBSTRATE_DIR/<env>/ (default /bulk/substrate/<env>/):
#
#   terraform init -reconfigure -backend-config="path=<SUBSTRATE_DIR>/<env>/terraform.tfstate"
#
# Not in the checkout, because a git worktree is deleted when its branch
# merges, and a state file in it goes with it. The state holds the platform
# and SMTP access keys (see README.md § Secrets in state), so it lives with
# the keyring, under the same directory mode, on the machine of a person who
# is allowed to hold the keyring.
#
# One ENV chooses the var-file and the state path, in substrate.sh. There is
# no second pin to keep in step.
# ----------------------------------------------------------------------------

terraform {
  backend "local" {}
}
