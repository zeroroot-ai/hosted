# ===============================================================
# enterprise/deploy/Makefile — the bringup verbs and the inner loop
# ===============================================================
# Primary targets (ADR-0083, the three verbs):
#   make substrate ENV=kind  — stage 0: bucket, relay, zone, keyring
#   make preflight ENV=kind  — prove every line of substrate.env live
#   make recreate ENV=kind   — preflight + stage 1 + stage 2, from nothing
#   make teardown ENV=kind MODE=wipe|preserve — destroy stage 1
#   make smoke               — shippability gate: Envoy edge TLS handshake
#   make restart-<svc>       — rebuild + kind-load + rollout one service
# ===============================================================

CLUSTER       ?= gibson
NAMESPACE     ?= gibson
KUBECTL       ?= kubectl --context kind-$(CLUSTER)
HELM          ?= helm --kube-context kind-$(CLUSTER)

# Versions are pinned to known-good releases.
#
# ARGOCD_VERSION: v3.1.16 (latest 3.1.x as of 2026-05-05).
#
# Bumped from v2.13.0 → v3.1.16 to fix deploy#369: ServerSideDiff in
# v2.13.x (including the latest v2.13.9 patch, EOL 2025-09-04) crashes on
# StatefulSet/gibson-gibson-workloads with:
#   "error reverting webhook removed fields in predicted live resource:
#    .spec.template.spec.containers: element 0: associative list with
#    keys has an element that omits key field 'name'"
# The bug is in v2.13's removeNonConfigMutations strategic-merge revert
# logic: it strips the `name` key from container list elements even
# though `name` IS the patch-merge-key, then trips its own input
# validation. Empirically verified on 2026-05-19 against the live kind
# cluster: v2.13.0 reproduces the error; v2.13.9 still reproduces it;
# v3.1.16 makes gibson-workloads reach the Sync phase successfully (no
# more ComparisonError).
#
# v3.1.x is on the current Argo CD support line; v3.x's gitops-engine
# version restructured the diff code paths and dropped the buggy
# revert-keyed-list branch.
ARGOCD_VERSION             ?= v3.1.16
CERT_MANAGER_VERSION       ?= v1.16.2
CNPG_VERSION               ?= 0.23.0
ESO_VERSION                ?= 0.18.2
PROM_OPERATOR_VERSION      ?= 65.5.0
SPIRE_CRDS_VERSION         ?= 0.5.0

GREEN := \033[0;32m
YELLOW:= \033[0;33m
RED   := \033[0;31m
NC    := \033[0m

.PHONY: check-apiserver-cidrs check-kind-apiserver-cidrs help require-charts apex-zone-init apex-zone-plan substrate preflight require-env require-mode teardown recreate eks-plan status smoke-signup smoke-entitlements stripe-listen verify-profile verify-saas-surfaces verify-selfhosted-seams verify-harness wait-root

help: ## Show available targets
	@echo "Usage: make <target>"
	@echo ""
	@echo "Bringup verbs (ADR-0083, ENV is required, no default):"
	@echo "  substrate ENV=<env>     stage 0: durable bucket, SMTP relay, DNS sub-zone, keyring. Writes substrate.env (kind, staging, drill, prod)"
	@echo "  preflight ENV=<env>     prove every line of substrate.env live. Exits non-zero on the first miss"
	@echo "  teardown ENV=<env> MODE=wipe|preserve   destroy stage 1. MODE has no default"
	@echo "                          preserve: backup, backup-verify with the keyring, destroy, print the backup name"
	@echo "                          wipe: destroy. Neither mode deletes anything from the durable bucket"
	@echo "  recreate ENV=drill INSTANCE_TYPE=<type>   use a type from bootstrap/ec2/gibson/envs/drill.instance-types (hosted#448)"
	@echo "  recreate ENV=drill NODE_COUNT=2           add a second node of the same type, for a proof that needs two nodes (hosted#453)"
	@echo "  recreate ENV=<env> [RESTORE_FROM=<name>]  preflight, stage 1 (the cluster and Argo), stage 2 (the platform, Synced+Healthy)"
	@echo "                          With no RESTORE_FROM every store bootstraps empty, always (ADR-0083)."
	@echo "                          With a name: the secret store first, then ESO, then the Velero restore and CNPG recovery"
	@echo ""
	@echo "EKS workspace helpers:"
	@echo "  eks-plan ENV=<env>      read-only terraform plan for one env (the unification gate)"
	@echo ""
	@echo "Apex zone (substrate/apex-zone, permanent, ADR-0083):"
	@echo "  apex-zone-plan          read-only plan of the zeroroot.ai apex zone and its mail records; must be empty"
	@echo ""
	@echo "Guards you can run by hand:"
	@echo "  check-teardown          the teardown verb fails closed (offline, stubbed kind/kubectl/aws)"
	@echo "  check-marketing-host    every overlay points at the one off-cluster marketing site (ADR-0077)"
	@echo ""
	@echo "Bringup sub-targets:"
	@echo "  wait-root               poll until all ArgoCD Applications are Synced+Healthy"
	@echo ""
	@echo "Shippability gates:"
	@echo "  smoke                   Envoy edge TLS handshake (dashboard → the app host; override with URL=)"
	@echo "  smoke-signup            Gate 3: signup-to-working e2e (deploy#88)"
	@echo "  smoke-entitlements      Entitlements seam: mTLS/DB/plans/grpcProvider + concrete limit (deploy#1006)"
	@echo "  verify-release          Run helm-test Pods (post-install assertions, deploy#355)"
	@echo "  verify-saas-surfaces    SaaS web surfaces: www / docs / app login (deploy#1041)"
	@echo "  verify-selfhosted-seams Self-hosted seams: login front door, signup, bootstrap, docs (deploy#1039)"
	@echo "  verify-harness          Offline: prove the two suites above fail closed with no cluster"
	@echo ""
	@echo "Variables:"
	@echo "  CLUSTER          $(CLUSTER)"
	@echo "  NAMESPACE        $(NAMESPACE)"
	@echo "  ARGOCD_VERSION   $(ARGOCD_VERSION)"

# ===============================================================
# Bringup verbs (ADR-0083): substrate, preflight, teardown, recreate.
# Each verb is also a GitHub workflow with the same name and inputs
# (.github/workflows/preflight.yml, teardown.yml, recreate.yml). The old
# eks-up / eks-down / verify-teardown targets are deleted (deploy#1745).
# The kind recreate is implemented here (deploy#1737); the kind teardown
# lands with deploy#1738 and the AWS bodies with deploy#1746
# (scripts/recreate-aws.sh, scripts/teardown-aws.sh).
#
# ENV is REQUIRED on the command line or in the environment. No line in this
# file gives it a default, and that includes the eks-* targets further down
# (hosted#404). A target that picks an environment by omission is how the
# wrong estate gets touched.
#
# One table row per environment: kind (bootstrap/kind/substrate/substrate.sh) and the
# AWS envs staging and prod (substrate/gibson-bootstrap/substrate.sh, deploy#1742).
#
# SUBSTRATE_DIR holds every environment's stage 0 state (keyring,
# substrate.env, and on kind the MinIO and CoreDNS data, on AWS the local
# Terraform state of stage 0) OUTSIDE the checkout: it must outlive a
# reboot, a deleted worktree and every cluster. Never under /tmp.
# ===============================================================
# Tombstone: the variable was named KIND_SUBSTRATE_DIR for one day and two
# workflows kept passing it after the rename, so the override was silently
# ignored and stage 0 fell back to /bulk on a CI runner (exit-test-vanilla
# run 33544911145). A dead name must fail, never fall through.
ifdef KIND_SUBSTRATE_DIR
$(error KIND_SUBSTRATE_DIR was renamed to SUBSTRATE_DIR (deploy#1753); set SUBSTRATE_DIR instead)
endif
SUBSTRATE_DIR ?= /bulk/substrate

# The chart source (ADR-0086). This repo holds none. CHARTS_ROOT is a checkout
# of zeroroot-ai/charts, a sibling directory by default, exactly as README.md
# says to clone it. The recreate verb packages from it and the baseline-*
# targets run the chart suites that live with the chart. Exported, so the
# scripts read the same value make does.
CHARTS_ROOT ?= $(abspath $(dir $(abspath $(lastword $(MAKEFILE_LIST))))/../charts)
export CHARTS_ROOT

# kubectl exec, attach and cp use SPDY, not WebSocket, in every verb on every
# substrate (kind, EC2, EKS). The WebSocket transport of kubectl drops stream
# bytes and the exec still exits 0: stdout was lost on kind ("Unknown stream
# id 1, discarding message", #253), and the stdin of `exec -i` arrived empty
# on the drill (runs 39171920065 and 39175834377). Exported, so each script a
# verb runs gets it. scripts/lib/ec2-cluster-access.sh sets it too, for the
# EC2 callers that do not run through make (drill-rotate-keys.sh).
export KUBECTL_REMOTE_COMMAND_WEBSOCKETS := false
SUBSTRATE_STATE_kind    := $(SUBSTRATE_DIR)/kind
SUBSTRATE_UP_kind       := bootstrap/kind/substrate/substrate.sh $(SUBSTRATE_STATE_kind)
SUBSTRATE_ENV_kind      := $(SUBSTRATE_STATE_kind)/substrate.env
SUBSTRATE_STATE_staging := $(SUBSTRATE_DIR)/staging
SUBSTRATE_UP_staging    := substrate/gibson-bootstrap/substrate.sh $(SUBSTRATE_STATE_staging) staging
SUBSTRATE_ENV_staging   := $(SUBSTRATE_STATE_staging)/substrate.env
# drill is the throwaway environment (ADR-0095). Its stage 0 OUTLIVES a drill —
# the bucket, the keyring, the relay and the delegated zone stay — and only its
# stage 1 is destroyed between runs.
SUBSTRATE_STATE_drill   := $(SUBSTRATE_DIR)/drill
SUBSTRATE_UP_drill      := substrate/gibson-bootstrap/substrate.sh $(SUBSTRATE_STATE_drill) drill
SUBSTRATE_ENV_drill     := $(SUBSTRATE_STATE_drill)/substrate.env
SUBSTRATE_STATE_prod    := $(SUBSTRATE_DIR)/prod
SUBSTRATE_UP_prod       := substrate/gibson-bootstrap/substrate.sh $(SUBSTRATE_STATE_prod) prod
SUBSTRATE_ENV_prod      := $(SUBSTRATE_STATE_prod)/substrate.env

require-env:
	@case "$(origin ENV)" in \
	  "command line"|environment|"environment override") ;; \
	  *) printf "$(RED)!$(NC) ENV is required and has no default. Run: make $(MAKECMDGOALS) ENV=<env>\n"; exit 2 ;; \
	esac

substrate: require-env ## Stage 0 for ENV: the durable bucket, SMTP relay, DNS sub-zone and keyring. Writes substrate.env (ADR-0083)
	@test -n "$(SUBSTRATE_UP_$(ENV))" || { printf "$(RED)!$(NC) ENV=$(ENV) has no stage 0 in this repo (kind, staging, drill, prod)\n"; exit 2; }
	@$(SUBSTRATE_UP_$(ENV))

preflight: require-env ## Prove every line of substrate.env live for ENV. Exits non-zero on the first miss (ADR-0083)
	@test -n "$(SUBSTRATE_ENV_$(ENV))" || { printf "$(RED)!$(NC) ENV=$(ENV) has no substrate.env location in this repo (kind, staging, drill, prod)\n"; exit 2; }
	@scripts/preflight.sh "$(SUBSTRATE_ENV_$(ENV))"
	@# Before stage 1, not after: an overlay with no apiserver egress rule comes up
	@# looking healthy and fails at OpenBao's first Kubernetes-auth login, 20 minutes
	@# in, with three words. Same reasoning as the archive-prefix refusal.
	@python3 scripts/check-apiserver-cidrs.py --env "$(ENV)"

# MODE has no default (ADR-0083). A teardown that picks a mode by omission
# is how a preserve teardown silently becomes a wipe.
require-mode:
	@case "$(MODE)" in \
	  wipe|preserve) ;; \
	  *) printf "$(RED)!$(NC) MODE is required and has no default. Run: make teardown ENV=<env> MODE=wipe or MODE=preserve\n"; exit 2 ;; \
	esac

# ===============================================================
# teardown — destroy stage 1 for ENV (ADR-0083, deploy#1738):
#   preserve  backup, backup-verify with the keyring, destroy, print the
#             backup name a later recreate must carry
#   wipe      destroy. Neither mode deletes anything from the durable
#             bucket: retention is the bucket lifecycle rule and nothing
#             else.
#
# The verb runs preflight first: a teardown that cannot prove the keyring
# and the bucket live must not destroy anything, because a preserve backup
# would be unverifiable and a later restore impossible.
#
# One table row per environment, the same shape as SUBSTRATE_UP_ above and
# RECREATE_UP_ below. The kind row is scripts/teardown-kind.sh. The staging
# and prod rows are scripts/teardown-aws.sh (deploy#1746), which wires the
# tested building blocks in bootstrap/eks/gibson/scripts/: eks-pre-destroy.sh (webhook
# sweep first, then Karpenter nodes, load balancers, ENIs, security groups),
# terraform destroy with the one bounded retry, and
# eks-post-destroy-verify.sh (zero billable resources, fail-closed,
# ADR-0070). The preserve half of both rows is the SAME code,
# scripts/lib/preserve-backup.sh.
# ===============================================================
TEARDOWN_DOWN_kind    := scripts/teardown-kind.sh $(SUBSTRATE_ENV_kind)
# Staging's stage 1 is one EC2 instance running k3s (ADR-0095, hosted#159),
# so its recreate and teardown are the plain-cluster pair. Production stays
# on EKS. Both pairs share everything that is not the cluster itself, in
# scripts/lib/bringup-before-cluster.sh and scripts/lib/bringup-after-cluster.sh.
TEARDOWN_DOWN_staging := scripts/teardown-ec2.sh $(SUBSTRATE_ENV_staging) staging
TEARDOWN_DOWN_drill   := scripts/teardown-ec2.sh $(SUBSTRATE_ENV_drill) drill
TEARDOWN_DOWN_prod    := scripts/teardown-aws.sh $(SUBSTRATE_ENV_prod) prod

teardown: require-env require-mode ## Destroy stage 1 for ENV. MODE=wipe|preserve is required, no default (ADR-0083)
	@test -n "$(TEARDOWN_DOWN_$(ENV))" || { printf "$(RED)!$(NC) ENV=$(ENV) has no teardown in this repo (kind, staging, drill, prod)\n"; exit 2; }
	@$(MAKE) --no-print-directory preflight ENV=$(ENV)
	@MODE="$(MODE)" CLUSTER="$(CLUSTER)" NS="$(NAMESPACE)" $(TEARDOWN_DOWN_$(ENV))

# ===============================================================
# recreate — stand ENV up from stage 0 (ADR-0083, deploy#1737).
#
# RESTORE_FROM=<name> is optional and is the ONLY way a recreate restores
# anything (ADR-0083). With no name every store bootstraps empty, always,
# even when the durable bucket holds a hundred backups. There is no `latest`,
# no auto-detect and no default that turns the restore on. A preserve
# teardown prints the name it verified as its last line, and that name is
# what a restore takes.
#
# Order of refusals, most specific first:
#   1. An environment without a recreate row fails and names the rows.
#   2. preflight runs and must pass before stage 1 starts.
#   3. A RESTORE_FROM that names no backup in the durable bucket fails
#      BEFORE the cluster is deleted, naming the object it looked for
#      (scripts/recreate-kind.sh; the guard is tests/harness/restore.bats).
#
# The kind row is scripts/recreate-kind.sh: stage 1 (the kind cluster with
# /dev/kvm mounted, then Argo CD from bootstrap/kind/gibson), the bringup keyring into
# the cluster (scripts/keyring-to-cluster.sh), and stage 2 (the gibson
# umbrella and the gibson-velero release as Argo Applications, synced to
# Synced+Healthy from this checkout's charts).
#
# The staging and prod rows are scripts/recreate-aws.sh (deploy#1746): stage
# 1 is the bootstrap/eks/gibson three-phase apply, the same keyring script writes the
# keyring, and stage 2 is Argo CD syncing the gitops overlay the env names.
# The restore half of both rows is the SAME code,
# scripts/lib/velero-restore.sh.
# ===============================================================
RECREATE_UP_kind    := scripts/recreate-kind.sh $(SUBSTRATE_ENV_kind)
RECREATE_UP_staging := scripts/recreate-ec2.sh $(SUBSTRATE_ENV_staging) staging
RECREATE_UP_drill   := scripts/recreate-ec2.sh $(SUBSTRATE_ENV_drill) drill
RECREATE_UP_prod    := scripts/recreate-aws.sh $(SUBSTRATE_ENV_prod) prod

recreate: require-env ## Stand ENV up from nothing: preflight, stage 1, stage 2 (ADR-0083). Restores only RESTORE_FROM=<name> (ADR-0083)
	@test -n "$(RECREATE_UP_$(ENV))" || { printf "$(RED)!$(NC) ENV=$(ENV) has no recreate in this repo (kind, staging, drill, prod)\n"; exit 2; }
	@test -z "$(INSTANCE_TYPE)" || scripts/check-instance-type.sh "$(ENV)" "$(INSTANCE_TYPE)"
	@test -z "$(NODE_COUNT)" || scripts/check-node-count.sh "$(ENV)" "$(NODE_COUNT)"
	@$(MAKE) --no-print-directory preflight ENV=$(ENV)
	@CLUSTER="$(CLUSTER)" NS="$(NAMESPACE)" OVERLAY="$(OVERLAY)" RESTORE_FROM="$(RESTORE_FROM)" INSTANCE_TYPE="$(INSTANCE_TYPE)" NODE_COUNT="$(NODE_COUNT)" $(RECREATE_UP_$(ENV))

# ===============================================================
# EKS workspace helpers: eks-init, eks-plan, and the verification targets
# eks-kubeconfig / eks-converge / eks-smoke (promote-staging.yml uses the
# last two). The eks-up / eks-down / eks-bringup / verify-teardown targets
# were deleted (deploy#1745, ADR-0083): the bringup verbs above are the
# only lifecycle entrypoints. Their AWS bodies are scripts/recreate-aws.sh
# and scripts/teardown-aws.sh (deploy#1746), which drive the tested building
# blocks in bootstrap/eks/gibson/scripts/ (eks-pre-destroy.sh,
# eks-post-destroy-verify.sh, eks-sweep-admission-webhooks.sh).
# ===============================================================
# ENV has no default (hosted#404). Each eks-* target depends on require-env
# and stops when ENV is not set.
#
# Which root serves which environment (ADR-0095):
#   prod     bootstrap/eks/gibson, the root of these targets
#   staging  bootstrap/ec2/gibson, one EC2 instance with k3s
#   drill    bootstrap/ec2/gibson
# In the EKS root, ENV selects a -var-file and a backend key. Every terraform
# invocation below must carry TF_EKS_VARS, or the plan fails on the unset
# env-identifying variables — which is the intended guard, not a bug.
EKS_DIR      := bootstrap/eks/gibson
TF_EKS       := terraform -chdir=$(EKS_DIR)
TF_EKS_VARS  := -var-file=envs/$(ENV).tfvars

# Initialise the Terraform backend for the selected ENV. Backend-config values
# are derived from ENV + the live account ID (the bucket name carries the account
# ID per backend.tf, kept out of the committed file for portability). REQUIRED
# before any apply/destroy on a fresh checkout: a from-zero standup (CI, a clean
# runner) has no local .terraform/, so `terraform apply` would fail "Backend
# initialization required" (deploy#962/#930 — the never-run gate gap).
# The state lives under tfstate/ in the env's durable bucket, which stage 0
# (make substrate ENV=<env>, substrate/gibson-bootstrap) created. Locking is S3
# native (use_lockfile), so there is no lock table and no KMS key (ADR-0083).
# exit-test-terraform.yml carries the same three values inline.
eks-init: require-env
	@printf "$(GREEN)▶$(NC) [eks-init] terraform init backend (ENV=$(ENV))...\n"
	@cd $(EKS_DIR) && acct=$$(aws sts get-caller-identity --query Account --output text) && \
	  terraform init -reconfigure -input=false \
	    -backend-config="key=tfstate/eks-gibson/terraform.tfstate" \
	    -backend-config="bucket=zeroroot-ai-$(ENV)-durable-$${acct}" \
	    -backend-config="use_lockfile=true" >/dev/null
	@printf "$(GREEN)  ✓$(NC) [eks-init] backend initialised\n"

# Read-only plan against the selected env's live state. The unification gate
# (deploy#1397): a `terraform plan` here that is NOT empty against staging
# means the refactor changed behaviour. Run it before every apply.
eks-plan: require-env eks-init
	@printf "$(GREEN)▶$(NC) [eks-plan] planning ENV=$(ENV) against live state...\n"
	@$(TF_EKS) plan $(TF_EKS_VARS) -input=false -lock=false

# ----------------------------------------------------------------------------
# substrate/apex-zone (deploy#1741, ADR-0083): the zeroroot.ai apex zone and its
# mail records. PERMANENT. This workspace has an init and a read-only plan
# here and nothing else: no apply target, no destroy target, no teardown mode.
# An apply is a deliberate, owner-approved change to company mail and is run
# by hand from substrate/apex-zone/README.md. The plan must be empty; exit code 2
# means the code and the live zone disagree, and the code is what gets fixed.
# scripts/check-apex-zone-ownership.py fails the build on any destroy of it.
# ----------------------------------------------------------------------------
APEX_ZONE_DIR := substrate/apex-zone

apex-zone-init:
	@printf "$(GREEN)▶$(NC) [apex-zone-init] terraform init (prod backend, key apex-zone/terraform.tfstate)...\n"
	@cd $(APEX_ZONE_DIR) && acct=$$(aws sts get-caller-identity --query Account --output text) && \
	  terraform init -input=false \
	    -backend-config="bucket=zeroroot-ai-prod-tfstate-$${acct}-us-east-1" \
	    -backend-config="dynamodb_table=zeroroot-ai-prod-tf-locks" \
	    -backend-config="kms_key_id=alias/zeroroot-ai-prod-tf-bootstrap" >/dev/null
	@printf "$(GREEN)  ✓$(NC) [apex-zone-init] backend initialised\n"

apex-zone-plan: apex-zone-init
	@printf "$(GREEN)▶$(NC) [apex-zone-plan] planning the apex zone against live state (must be empty)...\n"
	@TF_VAR_apex_zone_id="$$(scripts/apex-zone-id.sh)" terraform -chdir=$(APEX_ZONE_DIR) plan -input=false -lock=false -detailed-exitcode

# ENV-targeted convergence (S7, deploy#809) + smoke (S8, deploy#811) gates.
# Reuse the same wait-root + smoke-signup logic as kind, pointed at the EKS
# cluster. Needs AWS creds in the environment (the same ones the apply used).
AWS_REGION       ?= us-east-1
EKS_KUBECONFIG   ?= /tmp/eks-$(ENV).kubeconfig
ENV_DOMAIN_staging := staging.zeroroot.ai
ENV_DOMAIN_prod    := zeroroot.ai
ENV_DOMAIN          = $(ENV_DOMAIN_$(ENV))

# ENV=prod only. Staging has not been an EKS cluster since ADR-0095, so asking
# EKS for zeroroot-ai-staging fails; ADR-0095 makes `with-cluster` the staging
# path. The guard scripts/check-staging-not-ephemeral.py fails a workflow that
# calls this target with ENV=staging.
eks-kubeconfig: require-env
	@test "$(ENV)" != staging || { printf "$(RED)!$(NC) ENV=staging is not an EKS cluster (ADR-0095). Use: make with-cluster ENV=staging CMD='<command>'\n"; exit 2; }
	@aws eks update-kubeconfig --name zeroroot-ai-$(ENV) --region $(AWS_REGION) --kubeconfig $(EKS_KUBECONFIG) >/dev/null
	@printf "$(GREEN)  ✓$(NC) kubeconfig → $(EKS_KUBECONFIG)\n"

# Run one command against a cluster that is ALREADY UP, with the API reached
# through an SSM forward that lives exactly as long as the command (ADR-0095).
# This is how CI talks to a permanent staging without recreating it, and why
# the whole assertion sequence is one step rather than four.
.PHONY: with-cluster
with-cluster: require-env ## Run CMD against an existing EC2 cluster over SSM: ENV=<staging|drill> CMD='<command>'
	@test -n "$(CMD)" || { printf "$(RED)!$(NC) CMD is required. Run: make with-cluster ENV=$(ENV) CMD='kubectl get nodes'\n"; exit 2; }
	@scripts/with-cluster.sh "$(ENV)" bash -c '$(CMD)'

# ===============================================================
# purge-tenant-backup — delete the last backup of a deleted tenant before it
# expires (ADR-0075, hosted#439). The one purge script is in charts
# (charts#419, scripts/purge-tenant-backup.sh). It holds every refusal and the
# delete. This verb adds only ENV and the cluster access of that environment.
# The tenant name and TENANT_UID go to the script unchanged, through the
# environment, so make never re-quotes them.
#
# One table row per environment, the same shape as RECREATE_UP_ above:
#   kind           the kube context of the local cluster
#   staging/drill  scripts/with-cluster.sh, the SSM forward (ADR-0095)
#   prod           the EKS kubeconfig that eks-kubeconfig writes
# The runbook is bootstrap/eks/gibson/runbooks/RUNBOOK-purge-tenant-backup.md.
# ===============================================================
PURGE_WITH_kind    := env KUBECTL="kubectl --context kind-$(CLUSTER)"
PURGE_WITH_staging := scripts/with-cluster.sh staging
PURGE_WITH_drill   := scripts/with-cluster.sh drill
PURGE_WITH_prod    := env KUBECONFIG=$(EKS_KUBECONFIG)

.PHONY: purge-tenant-backup
purge-tenant-backup: require-env require-charts ## Delete the last backup of a deleted tenant: ENV=<env> TENANT=<name> [TENANT_UID=<uid>] (ADR-0075)
	@test -n "$$TENANT" || { printf "$(RED)!$(NC) TENANT is required and has no default. Run: make purge-tenant-backup ENV=$(ENV) TENANT=<tenant name>\n"; exit 2; }
	@$(if $(PURGE_WITH_$(ENV)),true,false) || { printf "$(RED)!$(NC) ENV=$(ENV) has no cluster access in this repo (kind, staging, drill, prod)\n"; exit 2; }
	@test "$(ENV)" != prod || $(MAKE) --no-print-directory eks-kubeconfig ENV=prod
	@TENANT_UID="$$TENANT_UID" $(PURGE_WITH_$(ENV)) "$(CHARTS_ROOT)/scripts/purge-tenant-backup.sh" "$$TENANT"

# ===============================================================
# zitadel-console — the Platform owner opens the Zitadel console through a
# private path (ADR-0093, hosted#437). The public edge has no route for the
# console or the Zitadel admin APIs (charts#398). The verb opens two
# port-forwards and a TLS proxy on 127.0.0.1, prints the browser command, and
# holds the path open until Ctrl-C. staging and drill reach the API over SSM
# (with-cluster.sh), prod through the EKS kubeconfig. The steps are the runbook
# runbooks/zitadel-console.md in zeroroot-ai/docs.
# ===============================================================
CONSOLE_WITH_staging := scripts/with-cluster.sh staging
CONSOLE_WITH_drill   := scripts/with-cluster.sh drill
CONSOLE_WITH_prod    := env KUBECONFIG=$(EKS_KUBECONFIG)

.PHONY: zitadel-console
zitadel-console: require-env ## Open the Zitadel console of ENV through a private path: ENV=<staging|drill|prod> (hosted#437)
	@$(if $(CONSOLE_WITH_$(ENV)),true,false) || { printf "$(RED)!$(NC) ENV=$(ENV) has no private console path in this repo (staging, drill, prod)\n"; exit 2; }
	@test "$(ENV)" != prod || $(MAKE) --no-print-directory eks-kubeconfig ENV=prod
	@$(CONSOLE_WITH_$(ENV)) scripts/zitadel-console.sh

eks-converge: require-env eks-kubeconfig
	@printf "$(GREEN)▶$(NC) [eks-converge] gating on ArgoCD Applications Synced+Healthy ($(ENV))...\n"
	@$(MAKE) wait-root KUBECTL="kubectl --kubeconfig $(EKS_KUBECONFIG)"
	@printf "$(GREEN)  ✓$(NC) [eks-converge] platform converged\n"

eks-smoke: require-env eks-kubeconfig
	@printf "$(GREEN)▶$(NC) [eks-smoke] signup smoke against app.$(ENV_DOMAIN)...\n"
	@CLUSTER_URL=https://app.$(ENV_DOMAIN) NAMESPACE=$(NAMESPACE) \
	  KUBECONFIG=$(EKS_KUBECONFIG) ./scripts/smoke-signup.sh
	@printf "$(GREEN)  ✓$(NC) [eks-smoke] signup smoke passed: signup → tenant Ready → data-plane secrets → api-edge auth chain. The mission itself is NOT executed — see the step-10 warning and deploy#1398.\n"

install-chart: ## Install the PUBLISHED OCI chart the customer way: CHART_VERSION=<v> [VALUES=<f>]. Targets EKS or a customer cluster with a registry pull credential, never kind (it cannot pull the private published images). The EKS estate installs via Argo; this is the direct helm path.
	@test -n "$(CHART_VERSION)" || { printf "$(RED)▶$(NC) install-chart: CHART_VERSION=<version> is required (the published OCI chart tag)\n"; exit 2; }
	@printf "$(GREEN)▶$(NC) [install-chart] helm upgrade --install of the published OCI chart $(CHART_VERSION) (crds → umbrella → velero)...\n"
	@NS=$(NAMESPACE) ./scripts/install-chart.sh "$(CHART_VERSION)" "$(VALUES)"

# -----------------------------------------------------------------------------
# Lifecycle helpers.
# -----------------------------------------------------------------------------
status:
	@$(KUBECTL) get pods -A | head -50

smoke: ## Verify dashboard → Envoy edge TLS handshake (zeroroot-ai/deploy#123)
	@printf "$(GREEN)▶$(NC) Envoy edge TLS smoke (dashboard pod → the app host)...\n"
	@./scripts/smoke-envoy-edge.sh

# ===============================================================
# wait-root — poll until every ArgoCD Application in the argocd namespace
# reaches Sync=Synced and Health=Healthy. Used standalone against the kind
# cluster and by eks-converge. scripts/recreate-kind.sh carries the same
# loop for the recreate verb, which cannot assume make's kubectl context.
#
# A cold bringup (CNPG → Zitadel → daemon) legitimately takes longer than the
# old flat 20m, so a healthy-but-slow stack used to fail spuriously (deploy#772).
# Instead: wait up to a generous hard cap (WAIT_ROOT_TIMEOUT, default 40m), but
# fail FAST if there is no forward progress (the Synced+Healthy count does not
# increase) for WAIT_ROOT_STALL (default 12m). Slow ⇒ keep waiting; stuck ⇒ fail
# with the list of laggards. Override either via env.
#
# Uses kubectl polling (not argocd CLI) to avoid requiring a port-forward
# or argocd login in the Makefile — kubectl already has the kind kubeconfig.
WAIT_ROOT_TIMEOUT ?= 2400
WAIT_ROOT_STALL   ?= 720
wait-root:
	@printf "$(GREEN)▶$(NC) Waiting for all ArgoCD Applications to be Synced+Healthy (hard cap $$(( $(WAIT_ROOT_TIMEOUT) / 60 ))m; stall-fail after $$(( $(WAIT_ROOT_STALL) / 60 ))m of no progress)...\n"
	@HARD_DEADLINE=$$(( $$(date +%s) + $(WAIT_ROOT_TIMEOUT) )); \
	LAST_HEALTHY=-1; LAST_PROGRESS=$$(date +%s); \
	while true; do \
	  NOW=$$(date +%s); \
	  TOTAL=$$($(KUBECTL) -n argocd get applications --no-headers 2>/dev/null | wc -l); \
	  HEALTHY=$$($(KUBECTL) -n argocd get applications \
	    -o jsonpath='{range .items[*]}{.status.sync.status},{.status.health.status}{"\n"}{end}' 2>/dev/null \
	    | grep -c "^Synced,Healthy$$" || true); \
	  if [ "$$TOTAL" -gt 0 ] && [ "$$HEALTHY" -eq "$$TOTAL" ]; then printf "\n"; break; fi; \
	  if [ "$$HEALTHY" -gt "$$LAST_HEALTHY" ]; then LAST_HEALTHY=$$HEALTHY; LAST_PROGRESS=$$NOW; fi; \
	  if [ "$$NOW" -ge "$$HARD_DEADLINE" ]; then \
	    printf "\n$(RED)!$(NC) Timeout: not all Applications Synced+Healthy within the hard cap.\n    Unhealthy apps:\n"; \
	    $(KUBECTL) -n argocd get applications \
	      -o jsonpath='{range .items[?(@.status.health.status!="Healthy")]}  {.metadata.name}: sync={.status.sync.status} health={.status.health.status}\n{end}'; \
	    exit 1; \
	  fi; \
	  STALLED=$$(( NOW - LAST_PROGRESS )); \
	  if [ "$$STALLED" -ge $(WAIT_ROOT_STALL) ]; then \
	    printf "\n$(RED)!$(NC) Stalled: no Synced+Healthy progress for $$(( STALLED / 60 ))m (stuck, not slow).\n    Unhealthy apps:\n"; \
	    $(KUBECTL) -n argocd get applications \
	      -o jsonpath='{range .items[?(@.status.health.status!="Healthy")]}  {.metadata.name}: sync={.status.sync.status} health={.status.health.status}\n{end}'; \
	    exit 1; \
	  fi; \
	  printf "  apps: %d/%d Synced+Healthy  [%dm since last progress; stall-fail at %dm]\r" \
	    "$$HEALTHY" "$$TOTAL" "$$(( STALLED / 60 ))" "$$(( $(WAIT_ROOT_STALL) / 60 ))"; \
	  sleep 10; \
	done
	@printf "$(GREEN)▶$(NC) All ArgoCD Applications are Synced+Healthy.\n"

# ===============================================================
# Live deployment-profile verification (deploy#1137)
# ===============================================================
# Asserts a standing cluster actually runs the profile it claims: images,
# entitlements seam, dashboard profile, signup front door, and that the edge
# serves rather than 500ing on an incoherent combination.
#
# Local by design. CICD-CONTEXT decision #3 keeps full-umbrella bringup out of
# CI (kind-standup-nightly.yml was deleted for that reason, deploy#1070), so the
# render-time half of this coverage lives in
# helm/gibson-workloads/tests/kind-profile-coherence.bats and runs on every
# chart PR; this is the half a render cannot do.
#
#   make verify-profile PROFILE=self-hosted
#   make verify-profile PROFILE=saas
verify-profile: ## Assert the live cluster runs PROFILE=self-hosted|saas (deploy#1137)
	@./scripts/verify-profile.sh $(PROFILE)

# ===============================================================
# Live surface + seam verification (deploy#1041 / deploy#1039)
# ===============================================================
# These extend verify-profile from "is the profile coherent" to "does the
# profile's user-visible surface actually serve". Both need a live cluster and
# both FAIL CLOSED: no cluster, wrong deployment profile, or a missing workload
# is exit 2, never a pass. verify-harness proves that property offline, so the
# guarantee is checked on every merge rather than assumed.
#
# Variables (all defaulted):
#   NAMESPACE   k8s namespace                          default: $(NAMESPACE)
#   DOMAIN      platform domain (hosts derive from it) default: zeroroot.ai
#   EDGE_ADDR   override the derived edge <ip>:<port>  default: from the Envoy Service
verify-saas-surfaces: ## SaaS surfaces live: www pages, pricing CTA, docs, app login (deploy#1041)
	@printf "$(GREEN)▶$(NC) [verify-saas-surfaces] probing the SaaS web surfaces...\n"
	@NAMESPACE=$(NAMESPACE) ./scripts/verify-saas-surfaces.sh

verify-selfhosted-seams: ## Self-hosted seams live: login front door, signup seam, bootstrap, docs (deploy#1039)
	@printf "$(GREEN)▶$(NC) [verify-selfhosted-seams] probing the self-hosted seams...\n"
	@NAMESPACE=$(NAMESPACE) ./scripts/verify-selfhosted-seams.sh

# Offline. Runs with no cluster, no Docker and no network — it stubs kubectl.
# In `make check` (hosted#359): until then no lane ran this target, so the proof
# that the live suites fail closed was itself never run.
verify-harness: ## Prove the live verification suites fail closed (offline, deploy#1039/#1041)
	@printf "$(GREEN)▶$(NC) [verify-harness] asserting the live suites cannot pass without a cluster...\n"
	@bats tests/harness/cluster-probe.bats
	@bats tests/harness/apex-zone-id.bats
	@printf "$(GREEN)  ✓$(NC) [verify-harness] both suites fail closed.\n"

# ===============================================================
# kind Stripe webhook tunnel (deploy#1135)
# ===============================================================
# kind has no public ingress, so Stripe cannot POST to the edge. The SaaS
# profile the kind cluster runs needs those deliveries — the receiver projects
# subscription_status into tenant_quotas, which is where the entitlements
# provider reads it — so without a tunnel signup completes and the tenant's
# billing state never converges.
#
# The target reconciles the signing secret before it forwards anything: the
# secret `stripe listen` signs with is NOT a Dashboard endpoint secret, and a
# mismatch fails every delivery with nothing but one WARN line in the receiver.
#
#   make stripe-listen                 reconcile, then forward (Ctrl+C to stop)
#   make stripe-listen ARGS=--check    reconcile/verify only, no listener
#   AUTO_RECONCILE=0 make stripe-listen   report the mismatch, mutate nothing
stripe-listen: ## kind Stripe webhook tunnel — reconciles the signing secret, then forwards (deploy#1135)
	@./scripts/stripe-listen.sh $(ARGS)

# ===============================================================
# Gate 3: signup-to-working e2e smoke (deploy#88)
# ===============================================================
# Proves the cluster is not just "all pods Ready" but actually serves a
# working signup-to-tenant-provisioning flow without needing Playwright.
#
# Requires:
#   - A converged cluster (make recreate ENV=kind ended Synced+Healthy).
#   - Kind cluster named $(CLUSTER) is the current kubectl context.
#   - scripts/smoke-signup.sh is executable.
#
# Variables (all have defaults; set to override):
#   NAMESPACE       default: $(NAMESPACE)
#   CLUSTER_URL     default: https://app.zeroroot.ai:30443
#   SMOKE_SLUG      auto-generated timestamp slug (set to reuse a known slug)
#   TIMEOUT_TENANT  seconds to wait for Tenant=Ready   default: 120
#   KEEP_TENANT     set "1" to skip cleanup after run  default: 0
smoke-signup: ## Gate 3 signup-to-working e2e (deploy#88)
	@printf "$(GREEN)▶$(NC) Gate 3 signup smoke...\n"
	@NAMESPACE=$(NAMESPACE) ./scripts/smoke-signup.sh

# Entitlements seam smoke (deploy#1006 / gibson#1026).
# Detects the four silent fail-open modes for the entitlements runtime seam:
#   1. entitlements-svc plain gRPC instead of mTLS (wrong BILLING_SVID)
#   2. entitlements-svc DB unreachable (missing PG* env)
#   3. plan registry load failure (lookupKey drift) → fail-open
#   4. daemon grpcProvider construction failure → ConfigProvider fallback (unlimited)
# Also asserts the concrete Team plan limit (concurrent_missions=10) through the
# full DB → plans-registry → seam path so a fail-open (returning 0/unlimited)
# makes this check FAIL.
# Env: NAMESPACE (default: $(NAMESPACE))
#      KEEP_ROW=1 to skip cleanup of the test tenant_quotas seed row
smoke-entitlements: ## Entitlements seam smoke: mTLS, DB, plans, grpcProvider, concrete limit (deploy#1006)
	@printf "$(GREEN)▶$(NC) Entitlements seam smoke...\n"
	@NAMESPACE=$(NAMESPACE) ./scripts/smoke-entitlements.sh

# -----------------------------------------------------------------------------
# verify-release — post-install chart-test invocation (deploy#355, slice 5.10)
# -----------------------------------------------------------------------------
# `helm test gibson-workloads` runs eight Pods that assert post-install cluster
# shape:
#   1. Service-reachability (curl probes against every component Service)
#   2. Bootstrap-Secret existence + non-emptiness
#   3. Bootstrap-ConfigMap existence + non-emptiness
#   4. FGA tuple-seed canary resolves to allowed=true
#   5. SPIRE attestation issues a workload SVID
#   6. Envoy admin reports gibson_daemon_grpc + ext_authz cluster healthy
#   7. Zitadel MACHINE_USER PAT exchange succeeds
#   8. Postgres / Redis / Neo4j data-plane reachable
#
# Each Pod is short-lived; the full sweep takes ~60-90s on a settled cluster.
# Each Pod carries the Helm hook policy
# `helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded`, so a
# successful run cleans up after itself and a failing run leaves the failed
# Pod around for `kubectl logs`.
#
# Pre-reqs (same as smoke-signup):
#   - The kind cluster is up and the gibson chart is installed.
#   - PlatformBootstrap=Ready (every signup-flow Secret has been minted).
#
# Diagnose a failure with:
#   kubectl -n $(NAMESPACE) logs gibson-workloads-test-<name>
# See docs/runbooks/RUNBOOK-helm-test.md.


# The umbrella PACKAGES gibson-operators/gibson-workloads from their working
# trees, charts/ dirs included — so it must be rebuilt whenever a leaf is.
# That is what the two stamps do here, and it is the deploy#1465 ordering
# expressed as a graph rather than as a sequence in a recipe.
# depend on it) whose CRD subcharts — spire-crds, prometheus-operator-crds —
# come from remote repositories, so it gets a full-refresh stamp like the
# umbrella, NOT the leaves' --skip-refresh. It gained these deps after this
# machinery landed; the CHARTS reach assertion in check-chart-deps-fresh.py
# caught the omission, exactly as its comment promised.

# The baseline-* scripts moved to zeroroot-ai/charts with the chart on
# 2026-09-04 (ADR-0086): they are chart suites and read helm/ relative to the
# chart root. These targets run them from CHARTS_ROOT, so `make baseline-verify`
# after a recreate, and `make baseline-up` in exit-test-substrate.yml, keep one
# entry point. require-charts names the missing checkout instead of letting
# make print "No such file or directory".
require-charts:
	@test -d "$(CHARTS_ROOT)/helm/gibson" || { printf "$(RED)!$(NC) no chart source at $(CHARTS_ROOT)/helm/gibson. Clone zeroroot-ai/charts there, or set CHARTS_ROOT=<checkout>\n"; exit 2; }

# charts-vendored: the sub-chart tarballs of the charts checkout exist. The
# restore tests read the vendored Velero CRD from them. Before the gate ran in
# two jobs, check-2core-overlay vendored them as a side effect, and check-verbs
# relied on it. A target that needs a tool says so (hosted merge gate split).
.PHONY: charts-vendored
charts-vendored: require-charts
	@ls "$(CHARTS_ROOT)"/helm/gibson-velero/charts/velero-*.tgz >/dev/null 2>&1 || $(MAKE) -C "$(CHARTS_ROOT)" chart-deps

# LOCAL ONLY, never CI (owner call 2026-09-15): kind and k3d are the developer
# story and CI is a different thing. A 2-vCPU runner does not fit this platform
# plus a k3s control plane — it evicted 35 pods when it was tried. What k3d is
# FOR is a k3s cluster on a workstation, which is what staging runs. Cilium is
# the network plugin on kind and on k3d (hosted#436).
#
# The local cluster on k3d — stage 1 only, no platform. kind remains the
# default local cluster and `make recreate ENV=kind` still builds it end to
# end; this is the second arm, for a developer who wants k3d's faster start,
# and it composes with the same installer (hosted#84).
.PHONY: k3d-up
k3d-up: ## Create the local k3d cluster on the stage 0 network (CLUSTER=, GRPC_PORT=, METRICS_PORT=)
	@./scripts/cluster-k3d.sh create

.PHONY: k3d-verify
k3d-verify: ## Prove the k3d cluster is usable by the platform: node Ready, ports free, bucket reachable, volumes Velero can read
	@./scripts/cluster-k3d.sh verify

.PHONY: k3d-down
k3d-down: ## Remove the local k3d cluster
	@./scripts/cluster-k3d.sh delete

.PHONY: baseline-up
baseline-up: require-charts ## Stand the platform up on a plain cluster, one shot, no manual steps (deploy#1627)
	@cd "$(CHARTS_ROOT)" && scripts/baseline-up.sh

.PHONY: baseline-plugins
baseline-plugins: ## recreate ENV=kind + the first-party reference plugins (ADR-0065 R5, github)
	@$(MAKE) recreate ENV=kind OVERLAY=plugins

.PHONY: baseline-set-secret
# The value comes on stdin, never on a command line: an argv is readable by
# every local user (ps, /proc) and lands in the shell history. VALUE= is
# refused by a make function, so the value never reaches the recipe's shell.
baseline-set-secret: require-charts ## Put an operator-supplied secret into the platform's OpenBao KV (KEY= PROP=, the value on stdin, never VALUE=)
	@$(if $(VALUE),printf "$(RED)!$(NC) VALUE= is refused: it puts the secret on a command line. The value you typed is on the argv of make and in your shell history: rotate it. Pipe the new value: printf '%%s\\\\n' \"\$$v\" | make baseline-set-secret KEY=<key> PROP=<property>\n" >&2; exit 2,true)
	@cd "$(CHARTS_ROOT)" && scripts/baseline-set-secret.sh "$(KEY)" "$(PROP)"

.PHONY: baseline-verify
baseline-verify: require-charts ## Assert a baseline install actually came up (OpenBao + ESO + restart)
	@cd "$(CHARTS_ROOT)" && scripts/baseline-verify.sh

# The budget guard renders the umbrella and gibson-velero from CHARTS_ROOT
# and builds the vendored sub-charts itself when they are absent, so it never
# reads a stale tarball.
.PHONY: check-2core-overlay
check-2core-overlay: require-charts ## The CI-only overlays keep the WHOLE node under the 2-vCPU runner budget (umbrella, Velero, metrics-server, kube-system, seeded tenant)
	@printf "$(GREEN)▶$(NC) check-2core-overlay...\n"
	@python3 scripts/check-2core-overlay.py --selftest
	@python3 scripts/check-2core-overlay.py

check-kind-apiserver-cidrs: ## The kind bringup names every address a pod reaches the kube-apiserver through (charts#80, staging 2026-09-10 and 2026-09-23)
	@printf "$(GREEN)▶$(NC) check-kind-apiserver-cidrs...\n"
	@python3 scripts/check-kind-apiserver-cidrs.py --selftest
	@python3 scripts/check-kind-apiserver-cidrs.py

check-apiserver-cidrs: ## Every cloud overlay names both apiserver addresses, derived from its own substrate (charts#80, staging 2026-09-10 and 2026-09-23)
	@printf "$(GREEN)▶$(NC) check-apiserver-cidrs...\n"
	@python3 scripts/check-apiserver-cidrs.py --selftest

.PHONY: check-pull-token-read-only
check-pull-token-read-only: ## A job token that becomes the GHCR pull token holds no write permission (review of hosted#44)
	@printf "$(GREEN)▶$(NC) check-pull-token-read-only...\n"
	@python3 scripts/check-pull-token-read-only.py --selftest
	@python3 scripts/check-pull-token-read-only.py
check: check-pull-token-read-only

.PHONY: check-bats-coverage
check-bats-coverage: ## Each tracked bats file is run by exactly one recipe of make check
	@printf "$(GREEN)▶$(NC) check-bats-coverage...\n"
	@python3 scripts/check-bats-coverage.py --selftest
	@python3 scripts/check-bats-coverage.py
check: check-bats-coverage

.PHONY: check-ci-lanes
check-ci-lanes: ## The merge gate keeps its parallel jobs, its three lanes and an aggregator that passes only on success
	@printf "$(GREEN)▶$(NC) check-ci-lanes...\n"
	@python3 scripts/check-ci-lanes.py --selftest
	@python3 scripts/check-ci-lanes.py
check: check-ci-lanes

.PHONY: check-kubectl-spdy
check-kubectl-spdy: ## A workflow job that runs kubectl exec sets KUBECTL_REMOTE_COMMAND_WEBSOCKETS=false (hosted#10)
	@printf "$(GREEN)▶$(NC) check-kubectl-spdy...\n"
	@python3 scripts/check-kubectl-spdy.py --selftest
	@python3 scripts/check-kubectl-spdy.py
check: check-kubectl-spdy

.PHONY: check-velero-kinds
check-velero-kinds: ## kubectl names a Backup or Restore with its group, because two operators own a kind named Backup (drill 39461957621)
	@printf "$(GREEN)▶$(NC) check-velero-kinds...\n"
	@python3 scripts/check-velero-kinds-qualified.py --selftest
	@python3 scripts/check-velero-kinds-qualified.py
check: check-velero-kinds

.PHONY: check-rotation-writeback
check-rotation-writeback: ## The keyring write-back of rotate-credentials.yml runs on any end of the job and reads its marker from the disk
	@printf "$(GREEN)▶$(NC) check-rotation-writeback...\n"
	@python3 scripts/check-rotation-writeback.py --selftest
	@python3 scripts/check-rotation-writeback.py
check: check-rotation-writeback

.PHONY: check-target-role-policy
check-target-role-policy: ## The rendered instance role policy of a target node holds only the allowlisted actions, and no second policy escapes the render
	@printf "$(GREEN)▶$(NC) check-target-role-policy...\n"
	@python3 scripts/check-target-role-policy.py --selftest
	@python3 scripts/check-target-role-policy.py
check: check-target-role-policy

.PHONY: check-bats-negation
check-bats-negation: ## No bats test asserts with a bare `! command`, which never fails the test (hosted#12)
	@printf "$(GREEN)▶$(NC) check-bats-negation...\n"
	@python3 scripts/check-bats-negation.py --selftest
	@python3 scripts/check-bats-negation.py
check: check-bats-negation

.PHONY: check-exit-tests-off-pr
check-exit-tests-off-pr: ## Exit tests never run on a pull request (ADR-0080)
	@printf "$(GREEN)▶$(NC) check-exit-tests-off-pr...\n"
	@python3 scripts/check-exit-tests-off-pr.py --selftest
	@python3 scripts/check-exit-tests-off-pr.py

.PHONY: check-role-callers
check-role-callers: ## Each workflow that assumes a pinned AWS role is named in its trust policy (hosted#656)
	@printf "$(GREEN)▶$(NC) check-role-callers...\n"
	@python3 scripts/check-role-callers.py --selftest
	@python3 scripts/check-role-callers.py

.PHONY: check-iam-arn-service
check-iam-arn-service: ## Each ARN in an IAM policy names a literal service; IAM refuses a wildcard service only at apply (hosted#106)
	@printf "$(GREEN)▶$(NC) check-iam-arn-service...\n"
	@python3 scripts/check-iam-arn-service.py --selftest
	@python3 scripts/check-iam-arn-service.py

.PHONY: check-kind-terraform
check-kind-terraform: ## The kind Terraform generates no credential and writes no Secret (ADR-0083, deploy#1732, deploy#1737)
	@printf "$(GREEN)▶$(NC) check-kind-terraform...\n"
	@python3 scripts/check-kind-terraform-no-seed.py --selftest
	@python3 scripts/check-kind-terraform-no-seed.py

.PHONY: check-marketing-host
check-marketing-host: ## Every overlay points at the one off-cluster marketing site; a per-env www host has no DNS record (ADR-0077)
	@printf "$(GREEN)▶$(NC) check-marketing-host...\n"
	@python3 scripts/check-marketing-host.py --selftest
	@python3 scripts/check-marketing-host.py

.PHONY: check-apex-zone
check-ses-rule-set-owner: ## The one SES receipt rule set belongs to substrate/apex-zone; no environment or teardown plan changes it (hosted#647)
	@printf "$(GREEN)▶$(NC) check-ses-rule-set-owner...\n"
	@python3 scripts/check-ses-rule-set-owner.py --selftest
	@python3 scripts/check-ses-rule-set-owner.py
check: check-ses-rule-set-owner

check-apex-zone: ## The apex zone and its mail records belong to substrate/apex-zone, never to an environment (ADR-0083, deploy#1741)
	@printf "$(GREEN)▶$(NC) check-apex-zone...\n"
	@python3 scripts/check-apex-zone-ownership.py --selftest
	@python3 scripts/check-apex-zone-ownership.py

# Stage 1 carries zero retain constructs (ADR-0083, deploy#1743): no
# prevent_destroy, no state rm, no teardown tag allowlist, no import script,
# no EBS capture in bootstrap/eks/gibson, and no reset target anywhere. CI runs it
# as the `retain-guard` job; exit-test-terraform.yml runs the same script
# with --plan against the live bootstrap/eks/gibson plan, which must declare no bucket.
.PHONY: check-no-retain
check-overlay-oidc-client-roles: ## Every overlay OIDC client declares its Zitadel roles (hosted#191)
	@printf "$(GREEN)▶$(NC) check-overlay-oidc-client-roles...\n"
	@python3 scripts/check-overlay-oidc-client-roles.py --selftest
	@python3 scripts/check-overlay-oidc-client-roles.py

.PHONY: check-saas-overlay
check-saas-overlay: ## The two SaaS overlay charts render, and each render holds its contract with the core chart (ADR-0074, hosted#413)
	@printf "$(GREEN)▶$(NC) check-saas-overlay...\n"
	@bats gitops/saas-overlay/billing-webhook/tests/overlay-render.bats
	@bats gitops/saas-overlay/entitlements-svc/tests/overlay-render.bats
check: check-saas-overlay

check-scp-attachments: ## Exactly two SCPs attach to the workload account, and no policy attaches to nothing (ADR-0073, hosted#418)
	@printf "$(GREEN)▶$(NC) check-scp-attachments...\n"
	@python3 scripts/check-scp-attachments.py --selftest
	@python3 scripts/check-scp-attachments.py

check-ec2-argocd-depends-on: ## In bootstrap/ec2/gibson, Argo CD is destroyed before the path to the API (the staging rebuild of 2026-10-06)
	@printf "$(GREEN)▶$(NC) check-ec2-argocd-depends-on...\n"
	@python3 scripts/check-ec2-argocd-depends-on.py --selftest
	@python3 scripts/check-ec2-argocd-depends-on.py

check-ec2-phase1-outputs: ## Each output the EC2 recreate reads after phase 1 names an aws_ resource, so the targeted apply writes it (hosted#609)
	@printf "$(GREEN)▶$(NC) check-ec2-phase1-outputs...\n"
	@python3 scripts/check-ec2-phase1-outputs.py --selftest
	@python3 scripts/check-ec2-phase1-outputs.py

check-drill-argocd-scope: ## The drill Argo CD project permits each entry of staging, except the self-hosted runners (hosted#618)
	@printf "$(GREEN)▶$(NC) check-drill-argocd-scope...\n"
	@python3 scripts/check-drill-argocd-scope.py --selftest
	@python3 scripts/check-drill-argocd-scope.py

check-no-operator-helm-release: ## Stage 1 installs Argo CD, never an operator that the umbrella owns (ADR-0083, hosted#409)
	@printf "$(GREEN)▶$(NC) check-no-operator-helm-release...\n"
	@python3 scripts/check-no-operator-helm-release.py --selftest
	@python3 scripts/check-no-operator-helm-release.py

check-no-retain: ## Stage 1 carries zero retain constructs (ADR-0083, deploy#1743)
	@printf "$(GREEN)▶$(NC) check-no-retain...\n"
	@python3 scripts/check-no-retain.py --selftest
	@python3 scripts/check-no-retain.py

# Stage 1 stays thin (ADR-0083, deploy#1744): a resource-type denylist over
# bootstrap/eks/gibson (Aurora, Secrets Manager, KMS, WAFv2, GuardDuty, SES, ACM) and a
# block-count ceiling. Runs its failing fixtures first, same rule and CI shape
# as check-no-retain; exit-test-terraform.yml also runs it with --plan.
.PHONY: check-stage1-shape
check-stage1-shape: ## Stage 1 declares no deleted resource class and stays under the block ceiling (ADR-0083, deploy#1744)
	@printf "$(GREEN)▶$(NC) check-stage1-shape...\n"
	@python3 scripts/check-stage1-shape.py --selftest
	@python3 scripts/check-stage1-shape.py


.PHONY: check-monitoring-rbac
check-monitoring-rbac: ## The monitoring stack reads no Secret outside its namespace (hosted#505)
	@printf "$(GREEN)▶$(NC) check-monitoring-rbac...\n"
	@python3 scripts/check-monitoring-rbac.py --selftest
	@python3 scripts/check-monitoring-rbac.py
check: check-monitoring-rbac

.PHONY: check-toolhive-install
check-toolhive-install: ## Each ToolHive operator install reads bootstrap/toolhive/values.yaml, so the proxy pods meet restricted (hosted#454)
	@printf "$(GREEN)▶$(NC) check-toolhive-install...\n"
	@python3 scripts/check-toolhive-install.py --selftest
	@python3 scripts/check-toolhive-install.py
check: check-toolhive-install

# The edge an environment asks for is one its cluster can give it (ADR-0095).
# Staging runs k3s with servicelb disabled, so a LoadBalancer Service there
# stays Pending for ever and the environment answers nothing while every
# Application reads Healthy.
.PHONY: check-plain-cluster-edge
check-plain-cluster-edge: ## The staging edge is a NodePort in the range stage 1 gives k3s, with no cloud annotation (ADR-0095, hosted#159)
	@printf "$(GREEN)▶$(NC) check-plain-cluster-edge...\n"
	@python3 scripts/check-plain-cluster-edge.py --selftest
	@python3 scripts/check-plain-cluster-edge.py

# Blocker 1 plans the root the environment really builds (ADR-0095). Planning
# the other one reports an estate nobody stands up, and reports it green.
.PHONY: check-blocker1-root
check-blocker1-root: ## The terraform exit test plans each environment's own stage 1 root, from its own state (ADR-0095, hosted#159)
	@printf "$(GREEN)▶$(NC) check-blocker1-root...\n"
	@python3 scripts/check-blocker1-root.py --selftest
	@python3 scripts/check-blocker1-root.py

# ---------------------------------------------------------------------------
# edge-exit-tests: the three edge exit tests on the Docker edge harness, for a
# local run. No kind cluster and no kubeconfig. Docker is the only runtime it
# needs. It is not a merge criterion: the merge gate is (ADR-0080). Each test
# also runs on `main` from its own workflow.
# ---------------------------------------------------------------------------
.PHONY: edge-exit-tests
edge-exit-tests: ## The three edge exit tests on the Docker harness (rate limit, WAF, misdirected authority), then tear down
	@command -v docker >/dev/null 2>&1 || { printf "$(RED)!$(NC) edge-exit-tests needs docker (the edge harness runs Envoy, ratelimit and Redis as containers)\n"; exit 2; }
	@docker info >/dev/null 2>&1 || { printf "$(RED)!$(NC) docker is installed but the daemon is not reachable\n"; exit 2; }
	@printf "$(GREEN)▶$(NC) edge-exit-tests: harness up...\n"
	@export WORK="$${WORK:-$$HOME/.cache/edge-harness}"; rm -rf "$$WORK"; mkdir -p "$$WORK"; \
	trap 'test/edge/harness.sh down >/dev/null 2>&1' EXIT; \
	test/edge/harness.sh up && . "$$WORK/env.sh" && \
	test/edge/exit-test-rate-limit.sh && test/edge/exit-test-waf.sh && test/edge/exit-test-misdirected-authority.sh

# The teardown verb's fail-closed suite (deploy#1738). Offline: `kind`,
# `kubectl` and `aws` are stubbed on PATH, so the whole preserve path runs
# with no cluster and no bucket, and every failing fixture asserts the same
# thing — `kind delete cluster` was never called, so the cluster is still
# running. The CI job runs the same one command.
# An env that pins a chart version carrying the charts#82 CRD split must
# install BOTH halves. Argo writes no Helm release record, so it will install
# the smaller gibson-crds and say nothing about the operator CRDs that are no
# longer in it.
# A member deleted from scripts/keyring.sh leaves its writers behind, and they
# fail only on a machine where that writer's input happens to exist.
.PHONY: check-keyring-members-exist
check-keyring-members-exist: ## Nothing writes a keyring member scripts/keyring.sh no longer defines
	@printf "$(GREEN)▶$(NC) check-keyring-members-exist...\n"
	@./scripts/check-keyring-members-exist.sh

# This repo holds no chart source (ADR-0086), so a script that reaches into a
# helm tree relative to itself resolves to nothing. Two did, and neither could
# run (hosted#363).
# An exit test with no workflow is not an exit test, and an aggregator that
# skips one of them says nothing about it (hosted#359).
.PHONY: check-edge-exit-tests-run
check-edge-exit-tests-run: ## Every edge exit test runs on main, and edge-exit-tests runs every one the Docker harness can (hosted#359)
	@printf "$(GREEN)▶$(NC) check-edge-exit-tests-run...\n"
	@./scripts/check-edge-exit-tests-run.sh --selftest
	@./scripts/check-edge-exit-tests-run.sh

# A values file that reads like an overlay and reaches no cluster absorbs edits
# forever, because the failure mode is silence (hosted#362).
.PHONY: check-values-files-are-named
check-values-files-are-named: ## Every values file under gitops/ is rendered by something (hosted#362)
	@printf "$(GREEN)▶$(NC) check-values-files-are-named...\n"
	@./scripts/check-values-files-are-named.sh --selftest
	@./scripts/check-values-files-are-named.sh

.PHONY: check-no-chart-source
check-no-chart-source: ## No chart source in this repo, except the two SaaS overlay charts (ADR-0086, hosted#415)
	@printf "$(GREEN)▶$(NC) check-no-chart-source...\n"
	@python3 scripts/check-no-chart-source.py --selftest
	@python3 scripts/check-no-chart-source.py
check: check-no-chart-source

.PHONY: check-helm-paths-rooted
check-helm-paths-rooted: ## No script reaches into a helm tree except through CHARTS_ROOT (hosted#363)
	@printf "$(GREEN)▶$(NC) check-helm-paths-rooted...\n"
	@python3 scripts/check-helm-paths-rooted.py --selftest
	@python3 scripts/check-helm-paths-rooted.py

# Launch blocker 5 (hosted#116): prod runs the chart digest staging tested,
# and a mismatch is blocked. The selftests prove every promotion guard can
# still fail, then check-promotion-order.py reads the tree: every env pins a
# version gitops/chart-digests.yaml records, and prod is never ahead of
# staging. Offline, no registry. exit-test-chart-signing.yml runs this same
# target, then the live digest-and-signature check.
.PHONY: check-promotion
check-promotion: ## Every promotion guard can still fail, and prod never pins a chart version staging has not pinned first (hosted#116)
	@printf "$(GREEN)▶$(NC) check-promotion...\n"
	@bash gitops/scripts/verify-chart-signature.sh --selftest
	@python3 gitops/scripts/check-promotion-order.py --selftest
	@bash gitops/scripts/check-prod-promotion.sh --selftest
	@bash gitops/scripts/check-promotion-isolation.sh --selftest
	@bash gitops/scripts/check-promotion-landed.sh --selftest
	@bash gitops/scripts/prune-orphans.sh --selftest
	@bats tests/harness/prove-promotion-audit.bats
	@bats tests/harness/prove-promotion-order.bats
	@bash gitops/scripts/bump-chart-version.sh --selftest
	@bash gitops/scripts/prod-on-green.sh --selftest
	@python3 gitops/scripts/check-promotion-order.py

# The two guards that read a change set. ci.yml runs this on pull requests
# with BASE set to the base branch; there is no change set on a push to main.
BASE ?= origin/main
.PHONY: check-promotion-pr
check-promotion-pr: ## A change set moves the prod pin only to the staging version, never a pin and its values.yaml together, and sets the belief trainer image the pinned chart reads (BASE=origin/main)
	@printf "$(GREEN)▶$(NC) check-promotion-pr against $(BASE)...\n"
	@bash gitops/scripts/check-prod-promotion.sh "$(BASE)"
	@bash gitops/scripts/check-promotion-isolation.sh "$(BASE)"
	@./scripts/check-overlay-belief-trainer.py --base "$(BASE)"

# Launch blocker 2 (hosted#122): the signup exit test's own guards. The
# driver's mail-parsing assertions and the member-Active assertion prove they
# can fail, and the overlay still names the Mailpit sink. Offline; needs node.
# exit-test-signup.yml runs this same lane, then the drill on a kind cluster.
.PHONY: check-signup-exit-test
check-signup-exit-test: ## The signup exit test's assertions can still fail, and its overlay still names the mail sink (hosted#122)
	@printf "$(GREEN)▶$(NC) check-signup-exit-test...\n"
	@bash test/signup/exit-test-signup.sh --selftest

.PHONY: check-demo-exit-test
check-demo-exit-test: ## The enrollment exit test's assertions can still fail: the drill and its in-image probe (zerocool-plugins#10)
	@printf "$(GREEN)▶$(NC) check-demo-exit-test...\n"
	@bash test/demo/exit-test-enrollment.sh --selftest

.PHONY: check-stub-names
check-stub-names: ## Every kubectl stub of tests/harness answers only the object names its test declares (hosted#654)
	@printf "$(GREEN)▶$(NC) check-stub-names...\n"
	@python3 scripts/check-stub-names.py --selftest
	@python3 scripts/check-stub-names.py
check: check-stub-names

.PHONY: check-charts-ref
check-charts-ref: ## An exit test installs only chart code of a branch, a tag or main of zeroroot-ai/charts, never a pull request ref
	@printf "$(GREEN)▶$(NC) check-charts-ref...\n"
	@bats tests/harness/charts-ref.bats
check: check-charts-ref

.PHONY: check-install-terraform
check-install-terraform: ## The one Terraform installer fails closed: a corrupted zip, a SHA256SUMS with no line for the zip, a binary that reports another version (blocker 1, run 35563392735)
	@printf "$(GREEN)▶$(NC) check-install-terraform...\n"
	@bats tests/harness/install-terraform.bats

.PHONY: check-stage0-store
check-stage0-store: ## stage 0 state, key slots and rotation record live in the durable bucket; every environment keeps its keyring in the Secrets Manager secret zeroroot-ai/<env>/keyring (ADR-0083, row 24)
	@printf "$(GREEN)▶$(NC) check-stage0-store...\n"
	@bats tests/harness/stage0-store.bats
	@bats tests/harness/rotate-credential.bats
	@bats tests/harness/recover-keyring.bats
	@bats tests/harness/drill-rotate-keys.bats
	@bats tests/harness/restart-pods.bats
	@bats tests/harness/stdin-secrets.bats
	@bats tests/harness/operator-boundary.bats
	@python3 scripts/check-keyring-secret.py --selftest
	@python3 scripts/check-keyring-secret.py
check: check-stage0-store

.PHONY: check-stripe-webhook-preflight
check-stripe-webhook-preflight: ## The Stripe webhook endpoint subscribes to every event the billing receiver consumes, and the preflight updates a drifted endpoint (staging run 38462291747)
	@printf "$(GREEN)▶$(NC) check-stripe-webhook-preflight...\n"
	@bats tests/harness/stripe-webhook-preflight.bats
check: check-stripe-webhook-preflight

.PHONY: check-cilium
check-cilium: ## Cilium has one pin, and each bringup fails when Cilium is absent or not ready (hosted#436)
	@printf "$(GREEN)▶$(NC) check-cilium...\n"
	@python3 scripts/check-cilium-pin.py --selftest
	@python3 scripts/check-cilium-pin.py
	@bats tests/harness/cilium.bats
check: check-cilium

.PHONY: check-ec2-node-labels
check-ec2-node-labels: ## Each k3s node of an EC2 env registers with its EC2 instance type (hosted#676)
	@printf "$(GREEN)▶$(NC) check-ec2-node-labels...\n"
	@bats tests/harness/ec2-node-labels.bats
check: check-ec2-node-labels

.PHONY: check-namespace-pod-security
check-namespace-pod-security: ## The gibson namespace enforces restricted, set in one place per env (hosted#438)
	@printf "$(GREEN)▶$(NC) check-namespace-pod-security...\n"
	@python3 scripts/check-namespace-pod-security.py --selftest
	@python3 scripts/check-namespace-pod-security.py
check: check-namespace-pod-security

.PHONY: check-secret-plane-alerts
check-secret-plane-alerts: ## Each monitoring env alerts on an ExternalSecret that is not Ready, and the bringup waits on them (hosted#174)
	@printf "$(GREEN)▶$(NC) check-secret-plane-alerts...\n"
	@python3 scripts/check-secret-plane-alerts.py --selftest
	@python3 scripts/check-secret-plane-alerts.py
check: check-secret-plane-alerts

.PHONY: check-workflows
check-workflows: ## The workflow files are valid: a bad expression is rejected at dispatch with no jobs and no log
	@printf "$(GREEN)▶$(NC) check-workflows...\n"
	@./scripts/check-workflows.sh

.PHONY: check-nlb-security-group
check-nlb-security-group: ## The EKS edge check fails an NLB with no own security group, or a target that does not admit it (hosted#508)
	@printf "$(GREEN)▶$(NC) check-nlb-security-group...\n"
	@bats tests/harness/nlb-security-group.bats
check: check-nlb-security-group

.PHONY: check-fleet-kvm
check-fleet-kvm: ## Each sandbox fleet node type exposes /dev/kvm, and a fleet node without it fails the bringup (hosted#446)
	@printf "$(GREEN)▶$(NC) check-fleet-kvm...\n"
	@python3 scripts/check-fleet-instance-types.py --selftest
	@python3 scripts/check-fleet-instance-types.py
	@bats tests/harness/kvm-nodes.bats
check: check-fleet-kvm

.PHONY: check-alert-delivery
check-alert-delivery: ## The monitoring exit test fails a failed email, no email, and a container at its memory limit (hosted#509)
	@printf "$(GREEN)▶$(NC) check-alert-delivery...\n"
	@bats tests/harness/alert-delivery.bats
check: check-alert-delivery

.PHONY: check-setec-cpu-template
check-setec-cpu-template: ## The setec CPU template exit test fails with no m8i node, a failed, skipped or missing scenario, and refuses a setec with no installed mode (setec#271)
	@printf "$(GREEN)▶$(NC) check-setec-cpu-template...\n"
	@bats tests/harness/setec-cpu-template.bats
check: check-setec-cpu-template

.PHONY: check-smoke-signup
check-smoke-signup: ## The bringup smoke signs up with the one signup driver and never pays on a live Stripe key (hosted#647)
	@printf "$(GREEN)▶$(NC) check-smoke-signup...\n"
	@bats tests/harness/smoke-signup.bats
	@node test/signup/driver.mjs --selftest
check: check-smoke-signup

.PHONY: check-baseline-set-secret-target
check-baseline-set-secret-target: ## make baseline-set-secret passes the value on stdin and refuses VALUE= (charts#679)
	@printf "$(GREEN)▶$(NC) check-baseline-set-secret-target...\n"
	@bats tests/harness/baseline-set-secret-target.bats
check: check-baseline-set-secret-target

.PHONY: check-smoke-probes-loud
check-smoke-probes-loud: ## No probe of the promotion proof sends its error to /dev/null and reads the refusal as an empty answer (staging run 38465547479)
	@printf "$(GREEN)▶$(NC) check-smoke-probes-loud...\n"
	@bash scripts/check-smoke-probes-loud.sh --selftest
	@bash scripts/check-smoke-probes-loud.sh
	@bats tests/harness/smoke-probe.bats
check: check-smoke-probes-loud

.PHONY: check-secrets-off-argv
check-secrets-off-argv: ## No shell script puts a token, a client secret or a password on a command line; the smoke sends each through a pipe (drill sweep row 28)
	@printf "$(GREEN)▶$(NC) check-secrets-off-argv...\n"
	@bats tests/harness/secrets-off-argv.bats
check: check-secrets-off-argv

.PHONY: check-drill-budget
check-drill-budget: ## The drill teardown is its own job, the drill job ends before its credential and its node, and Argo tracks the run's commit (drill sweep rows 19, 21, 26)
	@printf "$(GREEN)▶$(NC) check-drill-budget...\n"
	@bats tests/harness/drill-budget.bats
check: check-drill-budget

.PHONY: check-install-cluster-tools
check-install-cluster-tools: ## The cluster tool installer fails closed: a file that does not match its pinned sha256, a binary that reports another version (drill sweep row 29)
	@printf "$(GREEN)▶$(NC) check-install-cluster-tools...\n"
	@bats tests/harness/install-cluster-tools.bats
check: check-install-cluster-tools

.PHONY: check-edge-cert
check-edge-cert: ## The edge TLS certificate survives a recreate, and is stored only in the env's private Secrets Manager secret (row 9 of the drill path audit)
	@printf "$(GREEN)▶$(NC) check-edge-cert...\n"
	@python3 scripts/check-edge-cert-store.py --selftest
	@python3 scripts/check-edge-cert-store.py
	@bats tests/harness/edge-cert.bats
check: check-edge-cert

.PHONY: check-acme-challenge
check-acme-challenge: ## The EC2 teardown deletes the ACME challenge records a dead cluster left in the env zone, and the post-destroy check counts them (drill sweep row 27)
	@printf "$(GREEN)▶$(NC) check-acme-challenge...\n"
	@bats tests/harness/acme-challenge.bats
check: check-acme-challenge

.PHONY: check-drill-restore
check-drill-restore: ## A drill dispatch selects the restore half its input names, and a skipped restore cannot report green (hosted#443)
	@printf "$(GREEN)▶$(NC) check-drill-restore...\n"
	@bats tests/harness/drill-restore.bats
	@bats tests/harness/restore-markers-redis.bats
check: check-drill-restore

.PHONY: check-edge-names
check-edge-names: ## Each overlay lists the names of its edge certificate (app, api, docs, apex), so the bringup can restore the kept certificate (row 9)
	@printf "$(GREEN)▶$(NC) check-edge-names...\n"
	@python3 scripts/check-edge-names.py --selftest
	@python3 scripts/check-edge-names.py
check: check-edge-names

.PHONY: check-velero-prefix
check-velero-prefix: ## The EC2 and EKS recreate read the Velero prefix from the env overlay, under backups/velero/ (hosted#593)
	@printf "$(GREEN)▶$(NC) check-velero-prefix...\n"
	@bats tests/harness/velero-prefix.bats
check: check-velero-prefix

.PHONY: check-rotation-classes
check-rotation-classes: ## Each tested credential class has a rotation test, each test has a tested class, and the rotation job of a drill never runs beside its restore job (hosted#444)
	@printf "$(GREEN)▶$(NC) check-rotation-classes...\n"
	@python3 scripts/check-rotation-classes.py --selftest
	@bats tests/harness/rotation-masterkey.bats
	@python3 scripts/check-rotation-classes.py
	@bats tests/harness/drill-rotation.bats
	@bats tests/harness/rotation-helpers.bats
	@bats tests/harness/rotation-waits.bats
	@bats tests/harness/rotation-budget.bats
	@bats tests/harness/rotation-bounds.bats
check: check-rotation-classes

.PHONY: check-spiffe-literal
check-spiffe-literal: ## No tracked file holds a SPIFFE ID in the SaaS trust domain; one value names it (ADR-0164, hosted#435)
	@printf "$(GREEN)▶$(NC) check-spiffe-literal...\n"
	@python3 scripts/check-spiffe-literal.py --selftest
	@python3 scripts/check-spiffe-literal.py
check: check-spiffe-literal

.PHONY: check-openbao-tls-callers
check-openbao-tls-callers: ## No script or test calls OpenBao over plain HTTP: the listener serves TLS only (charts#540, hosted#536)
	@printf "$(GREEN)▶$(NC) check-openbao-tls-callers...\n"
	@python3 scripts/check-openbao-tls-callers.py --selftest
	@python3 scripts/check-openbao-tls-callers.py
check: check-openbao-tls-callers

.PHONY: check-node-count
check-node-count: ## The drill environment accepts a node count of 1 or 2, and a permanent one accepts none (hosted#453)
	@printf "$(GREEN)▶$(NC) check-node-count...\n"
	@bats tests/harness/node-count.bats
check: check-node-count

.PHONY: check-no-schedule
check-no-schedule: ## No workflow runs on a schedule (owner order, 2026-10-19)
	@printf "$(GREEN)▶$(NC) check-no-schedule...\n"
	@python3 scripts/check-no-schedule.py --selftest
	@python3 scripts/check-no-schedule.py
check: check-no-schedule

.PHONY: check-no-test-fixtures
check-no-test-fixtures: ## No environment turns on the exit-test runner identity or the daemon fixtures (gibson#1113)
	@printf "$(GREEN)▶$(NC) check-no-test-fixtures...\n"
	@python3 scripts/check-no-test-fixtures.py --selftest
check: check-no-test-fixtures

.PHONY: check-public-site-csp
check-public-site-csp: ## The docs edge sets a Content-Security-Policy (docs-site GHSA-6hc8-9whc-fxfw)
	@printf "$(GREEN)▶$(NC) check-public-site-csp...\n"
	@python3 scripts/check-public-site-csp.py --selftest
	@python3 scripts/check-public-site-csp.py
check: check-public-site-csp

.PHONY: check-overlay-crd-releases
check-overlay-crd-releases: ## An overlay pinning the split chart declares both CRD releases, at one version, operator CRDs first
	@printf "$(GREEN)▶$(NC) check-overlay-crd-releases...\n"
	@./scripts/check-overlay-crd-releases.py

.PHONY: check-overlay-monitoring-seam
check-overlay-monitoring-seam: ## The monitoring stack of each env can sync: no foreign namespace uses the chart's cluster store, and the prometheus-operator CRDs have one owner (hosted#423)
	@printf "$(GREEN)▶$(NC) check-overlay-monitoring-seam...\n"
	@python3 scripts/check-overlay-monitoring-seam.py --selftest
	@python3 scripts/check-overlay-monitoring-seam.py

.PHONY: check-overlay-velero-bucket
check-overlay-velero-bucket: ## Every AWS overlay gives gibson-velero its durable bucket, the same one as the Postgres archive (hosted#226)
	@printf "$(GREEN)▶$(NC) check-overlay-velero-bucket...\n"
	@./scripts/check-overlay-velero-bucket.py

.PHONY: check-overlay-disk-repo
check-overlay-disk-repo: ## Every cloud overlay names the setec disk registry that its stage 0 makes (D85, hosted#521)
	@printf "$(GREEN)▶$(NC) check-overlay-disk-repo...\n"
	@./scripts/check-overlay-disk-repo.py

.PHONY: check-overlay-values-read
check-overlay-values-read: ## Every key of each cloud overlay is read by the chart that env pins (hosted#537)
	@printf "$(GREEN)▶$(NC) check-overlay-values-read...\n"
	@./scripts/check-overlay-values-read.py

.PHONY: check-env-renders-at-pin
check-env-renders-at-pin: ## Each cloud env renders with the chart it pins, and each SaaS overlay egress group has a policy there (hosted#574)
	@printf "$(GREEN)▶$(NC) check-env-renders-at-pin...\n"
	@./scripts/check-env-renders-at-pin.py

.PHONY: check-teardown
check-teardown: ## The teardown verb and its AWS and EC2 scripts fail closed: no MODE, an EC2 preserve with no preserve input set, no keyring, a PartiallyFailed backup, an unretryable destroy, a leaked resource, an unswept webhook (deploy#1738, deploy#1746)
	@printf "$(GREEN)▶$(NC) check-teardown...\n"
	@bats tests/harness/teardown.bats
	@bats tests/harness/teardown-aws.bats
	@bats tests/harness/teardown-ec2.bats
	@bats tests/harness/targets.bats
	@python3 bootstrap/ec2/gibson/scripts/tagged-survivors.py --selftest
	@bats tests/harness/teardown-verify.bats
	@bats tests/harness/teardown-webhook-sweep.bats

# The bringup verbs' fail-closed suites. These existed and ran NOWHERE: the
# suites were written, they passed, and no target and no CI job called them,
# so nothing noticed when a verb drifted out from under them. That is the same
# defect class as the three teardown suites the split left pointing at a path
# that no longer existed (2026-09-14) — a guard that cannot fail is worse than
# no guard.
#
# tests/harness/restore.bats needs the chart source, like check-2core-overlay,
# so this target requires it. It was left out when the others were wired in on
# the reading that it was red: it is red only when run WITHOUT the chart source,
# which a worktree never has by default. With CHARTS_ROOT it is 25 of 25.
# A reprovision needs a fresh Postgres archive directory, and the AWS path has
# no per-bringup values seam, so the name is a reviewed commit (hosted#182).
# This picks the first free one and writes it; the operator commits it.
.PHONY: drill-archive-clear
drill-archive-clear: require-env ## Empty the Postgres archive directory of the drill at the end of a drill run. ENV=drill only (hosted#641)
	@scripts/drill-archive-clear.sh "$(SUBSTRATE_ENV_$(ENV))" "$(ENV)"

.PHONY: check-drill-archive-clear
check-drill-archive-clear: ## The drill teardown empties the drill archive, and the verb refuses every other env (hosted#641)
	@printf "$(GREEN)▶$(NC) check-drill-archive-clear...\n"
	@bats tests/harness/drill-archive-clear.bats
check: check-drill-archive-clear

# After a restore of staging or prod, the verb opens a PR that writes the new
# Postgres archive name into the overlay (D91). Once it has merged and Argo
# renders it, this removes the three recovery parameters from the live gibson
# Application, so Git is the truth again. EC2 envs go through the SSM forward;
# prod (EKS) uses the kubeconfig of the caller.
.PHONY: restore-settle
restore-settle: require-env ## After a restore's catch-up PR merges, remove the recovery parameters from the gibson Application (D91)
	@if [ "$(ENV)" = prod ]; then scripts/restore-settle.sh "$(ENV)"; \
	else scripts/with-cluster.sh "$(ENV)" scripts/restore-settle.sh "$(ENV)"; fi

.PHONY: check-app-of-apps-ignore
check-app-of-apps-ignore: ## The app-of-apps ignores only the restore parameters of Application gibson (D91)
	@printf "$(GREEN)▶$(NC) check-app-of-apps-ignore...\n"
	@./scripts/check-app-of-apps-ignore.py
check: check-app-of-apps-ignore

.PHONY: stamp-pg-archive
stamp-pg-archive: require-env ## Write the next free platformPostgres.backup.serverName into the ENV overlay (hosted#182)
	@scripts/stamp-pg-archive.sh "$(SUBSTRATE_ENV_$(ENV))" "$(ENV)"

# The trainer CronJob of a tenant has no pull secret, so the node pulls the
# belief trainer image from the ECR repository of the env (gibson#31). The
# recreate verbs copy the pinned image; this runs the copy alone, before a
# commit that moves the pin reaches main.
.PHONY: belief-trainer-image
belief-trainer-image: require-env ## Copy the belief trainer image that the ENV overlay pins into the ECR repository of the env (gibson#31)
	@scripts/belief-trainer-image.sh "$(SUBSTRATE_ENV_$(ENV))" "$(ENV)"

.PHONY: check-overlay-belief-trainer
check-overlay-belief-trainer: ## Every cloud overlay pins the belief trainer copy of its stage 0, with a digest (gibson#31)
	@printf "$(GREEN)▶$(NC) check-overlay-belief-trainer...\n"
	@./scripts/check-overlay-belief-trainer.py
	@bats tests/harness/belief-trainer-image.bats

.PHONY: check-verbs
# check-verbs runs in two targets of about five minutes each, one job each in
# ci.yml (the verbs file took 9 minutes 55 seconds of a 12 minute limit).
# check-verbs-a is an explicit list. check-verbs-b is every file of
# tests/harness that no other recipe or list of this Makefile names, so a new
# bats file runs in b by default. scripts/check-bats-coverage.py keeps each
# tracked bats file in exactly one recipe of `make check`.
VERBS_A_BATS := tests/harness/restore-ec2.bats tests/harness/restore.bats \
  tests/harness/recreate.bats tests/harness/instance-type.bats tests/harness/zitadel-console.bats
BATS_NAMED := $(shell grep -ho 'tests/harness/[A-Za-z0-9._-]*\.bats' $(firstword $(MAKEFILE_LIST)) | sort -u)
VERBS_B_BATS := $(filter-out $(BATS_NAMED),$(sort $(wildcard tests/harness/*.bats)))

.PHONY: check-verbs-a check-verbs-b
check-verbs: check-verbs-a check-verbs-b ## The bringup verbs fail closed: no ENV, a RESTORE_FROM that is not a backup, a used Postgres archive, a keyring member missing or unquoted, a substrate line that does not answer

check-verbs-a: require-charts charts-vendored ## The first half of check-verbs: the restore and recreate verbs
	@printf "$(GREEN)▶$(NC) check-verbs-a...\n"
	@bats $(VERBS_A_BATS)

check-verbs-b: require-charts charts-vendored ## The second half of check-verbs: every other bats file of tests/harness that no other recipe runs
	@printf "$(GREEN)▶$(NC) check-verbs-b...\n"
	@bats $(VERBS_B_BATS)

# Air-gap manifest freshness (deploy#1171): airgap/{images.txt,images.yaml} in charts
# are generated from `helm template` over every ci/ profile. Deliberately NOT in
# the aggregate `check` target — it pulls the umbrella's third-party chart
# dependencies, so it needs network and takes minutes, unlike the static gates.
# CI runs it as the `airgap-image-list` job on chart/airgap changes.
GO        ?= go
GO_MODULES := tools/cross-chart-check tools/envoy-route-check tools/digest-pin-check \
              tools/envoy-header-trust test/load

# GitHub Actions sets $CI. Exporting REQUIRE_ENVOY_PROOF here makes the Envoy
# identity-header proof (tools/envoy-header-trust) fail-closed for every recipe
# below: a missing container runtime, an unpullable image or a set
# ENVOY_HEADER_TRUST_SKIP becomes a test FAILURE rather than a skip that exits 0.
# Locally the variable stays unset, so `make test` still works without Docker —
# and says loudly that such a run proves nothing.
ifneq ($(CI),)
export REQUIRE_ENVOY_PROOF := 1
endif

.PHONY: check-staging-not-ephemeral
check-staging-not-ephemeral: ## No workflow tears staging down or rebuilds it (ADR-0095)
	@python3 scripts/check-staging-not-ephemeral.py --selftest
	@python3 scripts/check-staging-not-ephemeral.py

.PHONY: check-secret-contract
check-secret-contract: ## hosted vendors the chart's secret contract at the staging pin, and each key and hosted consumer in it matches gitops/ (hosted#422)
	@python3 scripts/check-secret-contract.py --selftest
	@python3 scripts/check-secret-contract.py

.PHONY: check

check: verify-harness check-staging-not-ephemeral check-secret-contract check-exit-tests-off-pr check-role-callers check-iam-arn-service check-overlay-oidc-client-roles check-apex-zone check-marketing-host check-no-retain check-no-operator-helm-release check-scp-attachments check-ec2-argocd-depends-on check-ec2-phase1-outputs check-drill-argocd-scope check-stage1-shape check-plain-cluster-edge check-blocker1-root check-kind-terraform check-2core-overlay check-kind-apiserver-cidrs check-apiserver-cidrs check-teardown check-verbs check-overlay-crd-releases check-overlay-monitoring-seam check-overlay-velero-bucket check-overlay-disk-repo check-overlay-belief-trainer check-overlay-values-read check-env-renders-at-pin check-keyring-members-exist check-values-files-are-named check-edge-exit-tests-run check-helm-paths-rooted check-install-terraform check-workflows check-promotion check-signup-exit-test check-demo-exit-test ## Run all deploy static gates
	@printf "$(GREEN)  ✓$(NC) [check] all deploy gates passed.\n"

# The ADR citation guard (hosted#433, ADR-0068). The check is the shared
# action of zeroroot-ai/.github at the commit that tree-guards.yml pins, so the
# pull request check and this target run the same code. The target reads the
# pin from the workflow, fetches the script at that commit, runs its failing
# fixtures, and then scans this tree against docs/adr-index.md.
.PHONY: check-adr-citations
check-adr-citations: ## Each ADR citation names a live ADR of docs/adr-index.md (hosted#433)
	@printf "$(GREEN)▶$(NC) check-adr-citations...\n"
	@set -eu; \
	sha="$$(sed -n 's|.*zeroroot-ai/\.github/\.github/workflows/adr-citations\.yml@\([0-9a-f]\{40\}\).*|\1|p' .github/workflows/tree-guards.yml)"; \
	[ -n "$$sha" ] || { echo "check-adr-citations: tree-guards.yml pins no adr-citations.yml commit" >&2; exit 2; }; \
	tmp="$$(mktemp)"; trap 'rm -f "$$tmp"' EXIT; \
	curl -fsSL --retry 3 "https://raw.githubusercontent.com/zeroroot-ai/.github/$$sha/actions/adr-citations/check-adr-citations.py" -o "$$tmp"; \
	python3 "$$tmp" --selftest; \
	REPO_ROOT="$(CURDIR)" python3 "$$tmp" --index docs/adr-index.md
check: check-adr-citations
