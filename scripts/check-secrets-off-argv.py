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

Scope: every tracked *.sh file under scripts/, test/, gitops/scripts/,
bootstrap/, substrate/ and .github/actions/. tests/ (the bats stubs) is out.

Usage:  scripts/check-secrets-off-argv.py [--selftest]
Exit:   0 clean, 1 a line breaks a rule, 2 the self-test is broken
"""
from __future__ import annotations

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCOPE = ["scripts", "test", "gitops/scripts", "bootstrap", "substrate", ".github/actions"]

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
    (re.compile(r'--arg\s+\w+\s+"?\$\{?\w*(?:TOKEN|SECRET|PASSWORD|PAT|API_KEY|_KEY)\b'),
     "a credential as a jq --arg (read it with env.NAME)"),
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
    files = subprocess.run(["git", "-C", str(ROOT), "ls-files", "--", *[f"{d}/*.sh" for d in SCOPE]],
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
