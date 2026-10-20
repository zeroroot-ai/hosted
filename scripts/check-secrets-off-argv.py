#!/usr/bin/env python3
"""check-secrets-off-argv.py: no shell script of this repo puts a credential
on a command line (drill sweep row 28).

An argv is readable by every local user (ps, /proc/<pid>/cmdline) and by a
process listing in a pod. A token, a client secret or a password in an
argument of curl, buf, grpcurl, kubectl exec or env leaks that way. The safe
forms move the value through a pipe or a file descriptor:

    curl -H @<(printf 'authorization: Bearer %s\\n' "$TOKEN") ...   # printf is a builtin
    printf '%s' "$body" | curl --data-binary @- ...
    printf '%s\\n' "$TOKEN" | kubectl exec -i ... -- sh -c 'IFS= read -r BAO_TOKEN; ...'
    grpcurl -expand-headers -H 'authorization: Bearer ${KEY}'       # grpcurl expands it

What fails, on each line that is not a comment, keyed by content:

  1. `Bearer $...` inside a double-quoted string: the shell expands the token
     into the argument.
  2. `-u "$...:` or `--user "$...:`: a user and a secret as one argument.
  3. `client_secret=$...` inside a double-quoted string.
  4. `env NAME=$...` where NAME ends in TOKEN, SECRET, PASSWORD or PAT.
  5. `--token "$...` or `--token=$...`.
  6. `jq --arg NAME "$...TOKEN"` (or SECRET, PASSWORD, PAT, KEY): jq gets the
     value as an argument. Read it from the environment: `X="$TOKEN" jq ...
     'env.X'`.

  7. `-d "...$SECRETNAME..."` (also --data, --data-raw, --data-binary): the
     body of a request holds the value. Send it on stdin with `-d @-`.
  8. `--api-key "$..."`: use the env value of the tool (STRIPE_API_KEY).
  9. `-e "NAME=...$SECRETNAME..."` or `-e "MC_HOST_...=..."`: a container
     environment value in the argument of docker. Export the value and pass
     `-e NAME` with no value.
 10. `-H "Cookie: ...$..."`, `-H "Authorization: ...$..."`, a metadata token
     or an api key header with an expanded value: use `-H @<(printf ...)`.
 11. `cypher-shell ... -p "$..."` or `--password "$..."`: use NEO4J_PASSWORD.

The name of a secret variable is matched without case: token, secret, pass,
password, pat, api_key, _key, cookie or jwe.

Scope: every tracked *.sh file under scripts/, test/, gitops/scripts/,
bootstrap/, substrate/, targets/ and .github/actions/, and each *.tftpl
template under bootstrap/, substrate/ and targets/. tests/ (the bats stubs)
is out.

Usage:  scripts/check-secrets-off-argv.py [--selftest]
Exit:   0 clean, 1 a line breaks a rule, 2 the self-test is broken
"""
from __future__ import annotations

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCOPE = ["scripts", "test", "gitops/scripts", "bootstrap", "substrate", "targets", ".github/actions"]
TEMPLATE_SCOPE = ["bootstrap", "substrate", "targets"]
NAME = r"\w*(?:token|secret|pass(?:word|wd)?|pat|api_key|_key|cookie|jwe)\b"

def double_quoted(line: str) -> str:
    """The text of the line that the shell reads inside double quotes, with
    single-quoted and unquoted text blanked. A `'...${X}'` is not expanded."""
    out, state, i = [], None, 0
    while i < len(line):
        c = line[i]
        if state is None:
            if c == "\\":
                i += 2; out.append("  "); continue
            if c in "'\"":
                state = c
            out.append(" ")
        elif state == "'":
            if c == "'":
                state = None
            out.append(" ")
        else:
            if c == "\\":
                out.append(line[i:i + 2]); i += 2; continue
            if c == '"':
                state = None
                out.append(" ")
            else:
                out.append(c)
        i += 1
    return "".join(out)


class InDouble:
    """A rule that matches only text inside double quotes."""
    def __init__(self, rx: str):
        self.rx = re.compile(rx)

    def search(self, line: str):
        return self.rx.search(double_quoted(line))


RULES = [
    (InDouble(r'Bearer \$'), "a bearer token expanded into an argument"),
    (re.compile(r'(?:\s-u|--user)[ =]"?\$\{?\w+\}?:'), "a user and a secret as one argument (-u)"),
    (InDouble(r'client_secret=\$'), "a client secret expanded into an argument"),
    (re.compile(r'\benv\s+(?:\w+=\S*\s+)*\w*(?:TOKEN|SECRET|PASSWORD|PAT)="?\$'), "a credential in an env argument"),
    (re.compile(r'--token[ =]"?\$'), "a token as a --token argument"),
    (re.compile(r'--arg\s+\w+\s+"?\$\{?' + NAME, re.I),
     "a credential as a jq --arg (read it with env.NAME)"),
    (re.compile(r'\s(?:-d|--data(?:-raw|-binary|-urlencode)?)[ =]"(?:[^"\\]|\\.)*?\$\{?' + NAME, re.I),
     "a credential in the body of a request (send it with -d @-)"),
    (re.compile(r'--api-key[ =]"?\$'), "an api key as an --api-key argument (use the env value of the tool)"),
    (re.compile(r'\s-e\s+"?\w+=[^\s]*\$\{?' + NAME, re.I),
     "a credential in a container environment argument (export it and pass -e NAME)"),
    (re.compile(r'\s-e\s+"?MC_HOST\w*='), "a MinIO credential in a container environment argument"),
    (re.compile(r'\s-H\s+"[^"]*(?:cookie|authorization|token|api-key)[^"]*\$', re.I),
     "a credential in a header argument (use -H @<(printf ...))"),
    (re.compile(r'cypher-shell\b[^\n]*\s(?:-p|--password)[ =]"?\$'), "a database password as a cypher-shell argument (use NEO4J_PASSWORD)"),
]


def findings(text: str, name: str) -> list[str]:
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        for rx, what in RULES:
            if rx.search(line):
                out.append(f"{name}:{n}: {what}: {line.strip()[:120]}")
    return out


GOOD = """\
curl -H @<(printf 'authorization: Bearer %s\\n' "$TOKEN") https://x
printf '%s' "$body" | curl --data-binary @- https://x
printf '%s\\n' "$T" | kubectl exec -i p -- sh -c 'IFS= read -r BAO_TOKEN; export BAO_TOKEN; exec bao kv list'
grpcurl -expand-headers -H 'authorization: Bearer ${KEY}' host:443 svc/M
timeout "${T}" grpcurl -expand-headers -H 'authorization: Bearer ${KEY}' \\
# a comment may say curl -H "authorization: Bearer ${TOKEN}" without a finding
env BAO_NAMESPACE="$NS" bao kv list
K="$API_KEY" jq -n --arg n "$NAME" '{k: env.K, n: $n}'
ADMIN_USER="$U" ADMIN_PASS="$P" jq -n '{p: env.ADMIN_PASS}' | curl -X POST -d @- https://x
STRIPE_API_KEY="$API_KEY" stripe listen --print-secret
MC_HOST_local="http://$U:$P@h" docker exec -i -e MC_CONFIG_DIR=/tmp/mc -e MC_HOST_local c mc
curl -H @<(printf 'Cookie: %s\\n' "$JWE") https://x
curl -fsS -H @<(printf 'X-aws-ec2-metadata-token: %s\\n' "$IMDS_TOKEN") http://169.254.169.254/x
NEO4J_USERNAME="$u" NEO4J_PASSWORD="$p" exec cypher-shell --format plain "$1"
"""
BAD = [
    ('curl -H "authorization: Bearer ${TOKEN}" https://x', "bearer token"),
    ('buf curl -H "Authorization: Bearer $1" https://x', "bearer token"),
    ('curl -u "${id}:${secret}" https://x', "(-u)"),
    ('curl -d "client_secret=${S}" https://x', "client secret"),
    ('kubectl exec p -- env BAO_TOKEN="${T}" bao kv list', "env argument"),
    ('kubectl exec p -- env BAO_NAMESPACE="$NS" VAULT_TOKEN=$T vault kv list', "env argument"),
    ('bao login --token "$T"', "--token"),
    ('timeout "${T}" curl -H "authorization: Bearer ${K}" x', "bearer token"),
    ('jq -n --arg k "$EXIT_TEST_ANTHROPIC_API_KEY" \'{k:$k}\'', "jq --arg"),
    ('-d "$(jq -n --arg id "$SESSION_ID" --arg tok "$SESSION_TOKEN" \'{}\')"', "jq --arg"),
    ('-d "$(jq -n --arg u "$ADMIN_USER" --arg p "$ADMIN_PASS" \'{}\')"', "jq --arg"),
    ('-d "$(jq -n --arg u "$email" --arg p "$pass" \'{}\')"', "jq --arg"),
    ('-d "$(jq -n --arg id "$session_id" --arg tok "$session_token" \'{}\')"', "jq --arg"),
    ('curl -d "{\\"password\\":\\"$PASSWORD\\"}" https://x', "body of a request"),
    ('stripe listen --api-key "$API_KEY" --print-secret', "--api-key"),
    ('docker exec -i -e "MC_HOST_local=http://$ROOT_USER:$ROOT_PASSWORD@127.0.0.1:9000" c mc', "container environment"),
    ('docker exec -e "MC_HOST_local=http://u:p@h" c mc', "MinIO credential"),
    ('curl -H "Cookie: __Secure-authjs.session-token=$JWE; x=1" https://x', "header argument"),
    ('curl -fsS -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/x', "header argument"),
    ("sh -c 'exec cypher-shell --format plain -u \"${A%%/*}\" -p \"${A#*/}\" \"$1\"'", "cypher-shell"),
]


def selftest() -> int:
    got = findings(GOOD, "good")
    if got:
        print("check-secrets-off-argv: selftest: a safe form failed:", *got, sep="\n  ", file=sys.stderr)
        return 2
    for line, want in BAD:
        got = findings(line, "bad")
        if not any(want in g for g in got):
            print(f"check-secrets-off-argv: selftest: {line!r} did not raise {want!r}: {got}", file=sys.stderr)
            return 2
    print(f"✅ self-test: {len(BAD)} unsafe lines each raise their rule; the safe forms and a comment pass")
    return 0


def main() -> int:
    if "--selftest" in sys.argv[1:]:
        return selftest()
    files = subprocess.run(["git", "-C", str(ROOT), "ls-files", "--",
                            *[f"{d}/*.sh" for d in SCOPE], *[f"{d}/*.tftpl" for d in TEMPLATE_SCOPE]],
                           check=True, capture_output=True, text=True).stdout.split()
    if not files:
        print("check-secrets-off-argv: no shell file in scope, so the scan saw nothing", file=sys.stderr)
        return 2
    got = []
    for f in files:
        got += findings((ROOT / f).read_text(encoding="utf-8", errors="replace"), f)
    if got:
        print("check-secrets-off-argv: a credential goes on a command line:", *got, sep="\n  ", file=sys.stderr)
        return 1
    print(f"✅ {len(files)} shell files put no credential on a command line")
    return 0


if __name__ == "__main__":
    sys.exit(main())
