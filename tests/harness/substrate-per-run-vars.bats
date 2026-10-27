#!/usr/bin/env bats
#
# substrate-per-run-vars.bats: substrate.sh refuses to run while a value that
# envs/<env>.tfvars takes per run ("# per-run TF_VAR: <name> ...") is unset or
# empty. Terraform takes an unset TF_VAR_<name> as "", and staging stage 0 on
# 2026-10-27 wrote empty GITHUB_APP_ID and GITHUB_APP_INSTALLATION_ID into
# substrate.env and the keyring secret with no error.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SUBSTRATE="$REPO_ROOT/substrate/gibson-bootstrap/substrate.sh"

setup() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/bin"
  # Past the check, the first outside call is aws. The stub stops the run
  # there, so a test never reaches AWS.
  printf '#!/usr/bin/env bash\necho "aws stub: $*" >&2\nexit 9\n' > "$TMP/bin/aws"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/terraform"
  chmod +x "$TMP/bin/aws" "$TMP/bin/terraform"
}
teardown() { rm -rf "$TMP"; }

run_substrate() {
  run env -u TF_VAR_argocd_github_app_id -u TF_VAR_argocd_github_app_installation_id \
    PATH="$TMP/bin:$PATH" "$@" bash "$SUBSTRATE" "$TMP/state" "${ENV_NAME:-staging}"
}

@test "each AWS env tfvars names its per-run values on one line" {
  for env in staging prod drill; do
    grep -qx '# per-run TF_VAR: argocd_github_app_id argocd_github_app_installation_id' \
      "$REPO_ROOT/substrate/gibson-bootstrap/envs/$env.tfvars" || { echo "no per-run line in $env.tfvars"; false; }
  done
}

@test "FAILING FIXTURE: with both per-run values unset, substrate.sh refuses before any call and names both" {
  run_substrate
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"TF_VAR_argocd_github_app_id TF_VAR_argocd_github_app_installation_id"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Nothing ran"* ]] || { echo "$output"; false; }
  [[ "$output" != *"aws stub"* ]] || { echo "$output"; false; }
  [ ! -e "$TMP/state" ] || { echo "the state directory was made"; false; }
}

@test "FAILING FIXTURE: an empty per-run value is refused like an unset one" {
  run_substrate TF_VAR_argocd_github_app_id=4900007 TF_VAR_argocd_github_app_installation_id=
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"unset or empty: TF_VAR_argocd_github_app_installation_id"* ]] || { echo "$output"; false; }
  [[ "$output" != *"aws stub"* ]] || { echo "$output"; false; }
}

@test "with both per-run values set, substrate.sh goes on to its first AWS call" {
  run_substrate TF_VAR_argocd_github_app_id=4900007 TF_VAR_argocd_github_app_installation_id=160662894
  [[ "$output" != *"unset or empty"* ]] || { echo "$output"; false; }
  # The stub answers nothing, and the script names the missing rule set: it
  # got past the check to its first AWS call.
  [[ "$output" == *"the account has no active SES receipt rule set"* ]] || { echo "$output"; false; }
}

@test "the drill env refuses the same way" {
  ENV_NAME=drill run_substrate
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"envs/drill.tfvars takes these values per run"* ]] || { echo "$output"; false; }
}
