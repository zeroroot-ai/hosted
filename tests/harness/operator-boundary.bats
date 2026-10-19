#!/usr/bin/env bats
#
# operator-boundary.bats: the IAM-user deny of PB-OperatorMaxPermissions
# (hosted#704, owner decision of 2026-10-18, option b) spares each IAM user
# whose access keys the bringup role rotates.
#
# scripts/drill-rotate-keys.sh rotates the users of USERS through
# scripts/substrate-rotate.sh, which creates a key with the bringup role. The
# boundary caps that role. A user the deny does not spare could never rotate
# again. Each such user is made by the substrate Terraform with path
# /substrate/ and the name zeroroot-ai-<env>-<user>.
#
# Offline. The check is one function. The FAILING FIXTURE feeds it a changed
# copy of the policy.
#
# Run:
#   bats tests/harness/operator-boundary.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
POLICY="$REPO_ROOT/bootstrap/eks/aws-org/policies/permission-boundary-operator.json"

# check POLICY_FILE: each rotated user is spared, and any other user is denied.
check() {
  python3 - "$1" "$REPO_ROOT/scripts/drill-rotate-keys.sh" "$REPO_ROOT/substrate/gibson-bootstrap" <<'PY'
import fnmatch, json, pathlib, re, sys
policy = json.load(open(sys.argv[1]))
users = re.search(r'^USERS="([^"]+)"', open(sys.argv[2]).read(), re.M).group(1).split()
tf = "".join(p.read_text() for p in pathlib.Path(sys.argv[3]).glob("*.tf"))
deny = [s for s in policy["Statement"] if s.get("Sid") == "DenyIAMUserCredentialsExceptSubstrateUsers"]
assert len(deny) == 1, "no IAM-user deny statement"
deny = deny[0]
assert deny["Effect"] == "Deny"
for a in ("iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile"):
    assert a in deny["Action"], "the deny does not name " + a
# No code attaches a managed policy to a user (the substrate Terraform uses
# inline user policies), so that deny covers every user.
attach = [s for s in policy["Statement"] if s.get("Effect") == "Deny" and "iam:AttachUserPolicy" in s.get("Action", [])]
assert attach and attach[0].get("Resource") == "*" and "NotResource" not in attach[0], "iam:AttachUserPolicy is not denied on every user"
spared = deny["NotResource"]
# The envs of the substrate Terraform, from its validation of var.environment.
var = re.search(r'variable "environment" \{.*?\n\}', tf, re.S).group(0)
envs = re.findall(r'"([a-z]+)"', re.search(r'contains\(\[([^\]]*)\]', var).group(1))
assert envs, "no env set in the substrate variable environment"
# Exactly the substrate users, and nothing that widens or disables the deny.
for st in policy["Statement"]:
    if st.get("Sid") in ("DenyIAMUserCredentialsExceptSubstrateUsers", "DenyIAMUserManagedPolicyAttach"):
        for k in ("Condition", "NotAction", "NotPrincipal", "Principal"):
            assert k not in st, "the statement %s has a %s, which can narrow or disable the deny" % (st["Sid"], k)
for env in envs:
    for u in users:
        name = "zeroroot-ai-%s-%s" % (env, u)
        assert re.search(r'name\s*=\s*"zeroroot-ai-\$\{var\.environment\}-%s"\s*\n\s*path\s*=\s*"/substrate/"' % re.escape(u), tf), \
            "the substrate Terraform has no user %s with path /substrate/" % u
        arn = "arn:aws:iam::447184491447:user/substrate/" + name
        assert any(fnmatch.fnmatchcase(arn, p) for p in spared), "the deny does not spare " + arn
for other in ("arn:aws:iam::447184491447:user/attacker",
              "arn:aws:iam::447184491447:user/substrate/zeroroot-ai-drill-admin",
              "arn:aws:iam::447184491447:user/zeroroot-ai-drill-platform",
              "arn:aws:iam::447184491447:user/substrate/zeroroot-ai-evil-platform",
              "arn:aws:iam::447184491447:user/substrate/zeroroot-ai-x/y-dns"):
    assert not any(fnmatch.fnmatchcase(other, p) for p in spared), "the deny spares " + other
expected = sorted("arn:aws:iam::*:user/substrate/zeroroot-ai-%s-%s" % (e, u) for e in envs for u in users)
assert sorted(spared) == expected, "the spared users are not exactly %s: %s" % (expected, sorted(spared))
print("ok")
PY
}

@test "the boundary denies IAM user credentials except for the rotated substrate users" {
  run check "$POLICY"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a policy that does not spare a rotated user is refused" {
  tmp="$(mktemp)"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); [s["NotResource"].remove(p) for s in d["Statement"] if s.get("Sid")=="DenyIAMUserCredentialsExceptSubstrateUsers" for p in list(s["NotResource"]) if p.endswith("-dns")]; json.dump(d,open(sys.argv[2],"w"))' "$POLICY" "$tmp"
  run check "$tmp"
  rm -f "$tmp"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the deny does not spare arn:aws:iam::447184491447:user/substrate/zeroroot-ai-"*"-dns"* ]]
}

@test "FAILING FIXTURE: a policy that spares every user is refused" {
  tmp="$(mktemp)"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); [s.__setitem__("NotResource",["arn:aws:iam::*:user/*"]) for s in d["Statement"] if s.get("Sid")=="DenyIAMUserCredentialsExceptSubstrateUsers"]; json.dump(d,open(sys.argv[2],"w"))' "$POLICY" "$tmp"
  run check "$tmp"
  rm -f "$tmp"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the deny spares arn:aws:iam::447184491447:user/attacker"* ]]
}

@test "FAILING FIXTURE: a wildcard in the environment of a spared user is refused" {
  tmp="$(mktemp)"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); [s.__setitem__("NotResource",["arn:aws:iam::*:user/substrate/zeroroot-ai-*-platform"]+s["NotResource"]) for s in d["Statement"] if s.get("Sid")=="DenyIAMUserCredentialsExceptSubstrateUsers"]; json.dump(d,open(sys.argv[2],"w"))' "$POLICY" "$tmp"
  run check "$tmp"
  rm -f "$tmp"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the deny spares arn:aws:iam::447184491447:user/substrate/zeroroot-ai-evil-platform"* ]]
}

@test "FAILING FIXTURE: a spared user with a trailing wildcard is refused" {
  tmp="$(mktemp)"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); [s.__setitem__("NotResource",[p+"*" if p.endswith("drill-platform") else p for p in s["NotResource"]]) for s in d["Statement"] if s.get("Sid")=="DenyIAMUserCredentialsExceptSubstrateUsers"]; json.dump(d,open(sys.argv[2],"w"))' "$POLICY" "$tmp"
  run check "$tmp"
  rm -f "$tmp"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the spared users are not exactly"* ]]
}

@test "FAILING FIXTURE: a Condition on the deny is refused" {
  tmp="$(mktemp)"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); [s.__setitem__("Condition",{"StringEquals":{"aws:RequestedRegion":"nowhere-1"}}) for s in d["Statement"] if s.get("Sid")=="DenyIAMUserCredentialsExceptSubstrateUsers"]; json.dump(d,open(sys.argv[2],"w"))' "$POLICY" "$tmp"
  run check "$tmp"
  rm -f "$tmp"
  [ "$status" -ne 0 ]
  [[ "$output" == *"has a Condition"* ]]
}

@test "FAILING FIXTURE: a policy that attaches managed policies to any user is refused" {
  tmp="$(mktemp)"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["Statement"]=[s for s in d["Statement"] if s.get("Sid")!="DenyIAMUserManagedPolicyAttach"]; json.dump(d,open(sys.argv[2],"w"))' "$POLICY" "$tmp"
  run check "$tmp"
  rm -f "$tmp"
  [ "$status" -ne 0 ]
  [[ "$output" == *"iam:AttachUserPolicy is not denied on every user"* ]]
}
