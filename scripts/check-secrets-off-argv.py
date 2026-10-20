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

Taint tracking (hosted#77). Each rule above reads the line as shell words, so
`-H 'Cookie: '"$JWE"` and `-e"API_TOKEN=$T"` are found as the same forms as
their plain spelling. A variable is sensitive when its name says so, and also
when the script assigns it from a secret (`P="$(kubectl get secret x -o
jsonpath='{.data.password}' | base64 -d)"`) or copies a sensitive variable,
whatever its name. The word rules, on a sensitive variable in an argument:
`-H`/`--header`, `-e`/`--env NAME=...`, `jq --arg/--argjson`, `-u user:...`,
`redis-cli -a/--pass`, `mc alias set`, `--password`, `mysql -p`,
`--from-literal`, helm `--set`, `gh --body` and `aws configure set`.

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


# --- taint tracking ---------------------------------------------------------
# A variable is sensitive when its name says so (NAME) or when the script
# assigns it from a secret source or from a sensitive variable, whatever its
# name: P="$(kubectl get secret x -o jsonpath=... | base64 -d)". The rules
# below read each command as words, so quoting tricks (-H 'Cookie: '"$JWE",
# -e"NAME=$X") cannot hide an expansion.

# A command that reads a secret. The value is sensitive only when the secret
# or the key it names says so: a project id from a Secret is not a credential.
SOURCE_CMD = re.compile(
    r"\bbase64\s+(?:-d|--decode)|get-secret-value|keyring\.sh\s+get|\b(?:bao|vault)\s+(?:kv\s+get|read)|\bsecret_data\b"
    r"|\bcat\s+\S*(?:token|secret|passw|apikey|api_key|\.key\b)",
    re.I,
)
SOURCE_WORD = re.compile(r"token|secret|pass|\bpat\b|key|cred|cookie|jwe|bearer", re.I)


def reads_secret(rhs: str) -> bool:
    return bool(SOURCE_CMD.search(rhs)) and bool(SOURCE_WORD.search(re.sub(r"get\s+secret", "", rhs)))


# `B="$A"`, `B=$A`, `B="${A}"`, `B="$(printf '%s' "$A")"`: a copy keeps the secret.
COPY = re.compile(r'^\s*"?(?:\$\{?(\w+)\}?|\$\(\s*printf\s+\S+\s+"?\$\{?(\w+)\}?"?\s*\))"?\s*$')
SENSITIVE_NAME = re.compile(r"(?:token|secret|pass(?:word|wd)?|\bpat\b|^pw$|_pw$|api_?key|_key$|cookie|jwe|credential|bearer|session_?token)", re.I)
ASSIGN = re.compile(r"^\s*(?:export\s+|local\s+|declare\s+(?:-\w+\s+)?|readonly\s+)?([A-Za-z_]\w*)=(.*)$")
VAR = re.compile(r"\$\{?([A-Za-z_]\w*)")


def tainted_names(lines: list[str]) -> set[str]:
    """The names that carry a secret in this file."""
    assigns = []
    for line in lines:
        if line.lstrip().startswith("#"):
            continue
        m = ASSIGN.match(line)
        if m:
            assigns.append((m.group(1), m.group(2)))
        r = re.match(r"^\s*read\s+(?:-\w+\s+)*([A-Za-z_]\w*)\s*$", line)
        if r and SENSITIVE_NAME.search(r.group(1)):
            assigns.append((r.group(1), "read"))
    tainted = {n for n, _ in assigns if SENSITIVE_NAME.search(n)}
    changed = True
    while changed:
        changed = False
        for n, rhs in assigns:
            if n in tainted:
                continue
            c = COPY.match(rhs)
            src = (c.group(1) or c.group(2)) if c else None
            if reads_secret(rhs) or (src and (src in tainted or SENSITIVE_NAME.search(src))):
                tainted.add(n)
                changed = True
    return tainted


class Word:
    def __init__(self, text: str, names: set[str]):
        self.text = text
        self.names = names

    def secret(self, tainted: set[str]) -> bool:
        return any(n in tainted or SENSITIVE_NAME.search(n) for n in self.names)


def substitutions(line: str) -> tuple[str, list[str]]:
    """The line with each $(...) and <(...) body cut out, and the bodies. A
    body is analysed as a line of its own, so what it expands is seen."""
    out, bodies, i = [], [], 0
    quote = ""
    while i < len(line):
        c = line[i]
        if quote == "'":
            out.append(c)
            if c == "'":
                quote = ""
        elif line.startswith(("$(", "<("), i) and not line.startswith("$((", i):
            depth, j = 1, i + 2
            while j < len(line) and depth:
                depth += (line[j] == "(") - (line[j] == ")")
                j += 1
            bodies.append(line[i + 2:j - 1])
            out.append("__SUBST__")
            i = j
            continue
        else:
            if c == "'" and not quote:
                quote = "'"
            elif c == '"':
                quote = "" if quote == '"' else '"'
            out.append(c)
        i += 1
    return "".join(out), bodies


def segments(line: str) -> list[list[Word]]:
    """The simple commands of a line, each a list of words. The text of a word
    has its quotes removed. Its names are the variables that the shell expands
    in it: outside single quotes."""
    segs: list[list[Word]] = [[]]
    text, quote, names, started = [], "", set(), False
    i = 0

    def end_word():
        nonlocal text, names, started
        if started:
            segs[-1].append(Word("".join(text), names))
        text, names, started = [], set(), False

    skip_next = False
    while i < len(line):
        c = line[i]
        if quote == "'":
            if c == "'":
                quote = ""
            else:
                text.append(c)
        elif quote == '"':
            if c == "\\" and i + 1 < len(line):
                text.append(line[i + 1]); i += 1
            elif c == '"':
                quote = ""
            else:
                text.append(c)
                if c == "$":
                    m = VAR.match(line, i)
                    if m:
                        names.add(m.group(1))
        else:
            if c in "'\"":
                quote = c; started = True
            elif c == "\\" and i + 1 < len(line):
                text.append(line[i + 1]); started = True; i += 1
            elif c.isspace():
                end_word()
            elif line.startswith(("&&", "||"), i):
                end_word(); segs.append([]); i += 1
            elif c in "|;&":
                end_word(); segs.append([])
            elif c == "#" and not started:
                break
            elif c in "<>":
                # A redirection: its operator and its target are not arguments.
                end_word()
                j = i
                while j < len(line) and line[j] in "<>&":
                    j += 1
                i = j
                while i < len(line) and line[i].isspace():
                    i += 1
                k = i
                while k < len(line) and not line[k].isspace() and line[k] not in "|;&":
                    k += 1
                i = k - 1
            else:
                text.append(c); started = True
                if c == "$":
                    m = VAR.match(line, i)
                    if m:
                        names.add(m.group(1))
        i += 1
    end_word()
    return [sg for sg in segs if sg]


def command_of(words: list[Word]) -> tuple[str, list[Word]]:
    """The command name, and its arguments, after leading NAME=value words and
    a wrapper such as env, sudo, exec, timeout or kubectl exec ... --."""
    i = 0
    while i < len(words) and re.match(r"^[A-Za-z_]\w*=", words[i].text):
        i += 1
    while i < len(words) and words[i].text in ("env", "sudo", "exec", "command", "nohup", "time"):
        i += 1
        while i < len(words) and re.match(r"^[A-Za-z_]\w*=", words[i].text):
            i += 1
    if i < len(words) and words[i].text == "timeout":
        i += 2
    if i >= len(words):
        return "", []
    return words[i].text.rsplit("/", 1)[-1], words[i + 1:]


def option_values(args: list[Word], names: tuple[str, ...]):
    """Each (option, value word) pair: `-H v`, `--header v`, `-Hv`, `--header=v`."""
    for i, w in enumerate(args):
        for opt in names:
            if w.text == opt and i + 1 < len(args):
                yield opt, args[i + 1]
            elif opt.startswith("--") and w.text.startswith(opt + "="):
                yield opt, Word(w.text[len(opt) + 1:], w.names)
            elif not opt.startswith("--") and w.text.startswith(opt) and len(w.text) > len(opt):
                yield opt, Word(w.text[len(opt):], w.names)


def word_findings(line: str, tainted: set[str]) -> list[str]:
    out = []
    text, bodies = substitutions(line)
    for body in bodies:
        out += word_findings(body, tainted)
    for seg in segments(text):
        cmds = [command_of(seg)]
        if any(w.text == "--" for w in seg):
            k = [w.text for w in seg].index("--")
            cmds.append(command_of(seg[k + 1:]))
        for cmd, args in cmds:
            if not cmd:
                continue
            def sec(w: Word) -> bool:
                return w.secret(tainted)
            for opt, v in option_values(args, ("-H", "--header")):
                if sec(v):
                    out.append("a credential in a header argument (use -H @<(printf ...))")
            for opt, v in option_values(args, ("-e", "--env")):
                if sec(v) and re.match(r"^\w+=", v.text):
                    out.append("a credential in a container environment argument (export it and pass -e NAME)")
            for i, w in enumerate(args):
                if w.text in ("--arg", "--argjson") and i + 2 < len(args) + 0 and sec(args[i + 2]):
                    out.append("a credential as a jq --arg (read it with env.NAME)")
            for opt, v in option_values(args, ("-u", "--user")):
                if sec(v) and ":" in v.text:
                    out.append("a user and a secret as one argument (-u)")
            if cmd == "redis-cli":
                for opt, v in option_values(args, ("-a", "--pass")):
                    if sec(v):
                        out.append("a password as a redis-cli argument (use REDISCLI_AUTH)")
            if cmd == "mc" and [a.text for a in args[:2]] == ["alias", "set"] and any(sec(a) for a in args[2:]):
                out.append("a credential in the arguments of mc alias set (use MC_HOST_<alias>)")
            for opt, v in option_values(args, ("--password", "--passwd", "--pass")):
                if sec(v):
                    out.append("a password as a --password argument (use the environment of the tool)")
            if cmd in ("mysql", "mysqldump", "mariadb", "cypher-shell"):
                for opt, v in option_values(args, ("-p",)):
                    if sec(v):
                        out.append("a database password as an argument (use the environment of the tool)")
            for opt, v in option_values(args, ("--from-literal",)):
                if sec(v):
                    out.append("a credential in --from-literal (use --from-file or --from-env-file)")
            for opt, v in option_values(args, ("--set", "--set-string")):
                if sec(v) and re.match(r"^[\w.\[\]-]+=", v.text):
                    out.append("a credential in a helm --set value (use a values file on stdin: -f -)")
            if cmd == "gh":
                for opt, v in option_values(args, ("--body", "-b")):
                    if sec(v):
                        out.append("a credential as a gh --body argument (send it on stdin)")
            if cmd == "aws" and [a.text for a in args[:2]] == ["configure", "set"] and any(sec(a) for a in args[2:]):
                out.append("a credential in aws configure set (use the environment or a credentials file)")
    return out


def logical_lines(text: str) -> list[tuple[int, str]]:
    """The lines of a script with each backslash continuation joined, and the
    body of a heredoc left out."""
    raw = text.split("\n")
    out, i = [], 0
    while i < len(raw):
        start, line = i + 1, raw[i]
        while line.rstrip().endswith("\\") and i + 1 < len(raw):
            i += 1
            line = line.rstrip()[:-1] + " " + raw[i].strip()
        i += 1
        out.append((start, line))
        m = re.search(r"<<-?\s*\\?['\"]?([A-Za-z_]\w*)['\"]?(?!<)", line) if "<<<" not in line else None
        if m:
            while i < len(raw) and raw[i].strip() != m.group(1):
                i += 1
            i += 1
    return out


def findings(text: str, name: str) -> list[str]:
    out = []
    seen = set()
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        for rx, what in RULES:
            if rx.search(line):
                out.append(f"{name}:{n}: {what}: {line.strip()[:120]}")
                seen.add((n, what))
    lines = logical_lines(text)
    tainted = tainted_names([l for _, l in lines])
    for n, line in lines:
        if line.lstrip().startswith("#"):
            continue
        for what in word_findings(line, tainted):
            if (n, what) not in seen:
                out.append(f"{name}:{n}: {what}: {line.strip()[:120]}")
                seen.add((n, what))
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
PROJECT_ID="$(kubectl get secret z -o jsonpath='{.data.project_id}' | base64 -d)"
jq -nc --arg p "$PROJECT_ID" '{projectId:$p}'
docker exec -i -e API_TOKEN c cmd
helm upgrade x y --set image.tag="$TAG"
kubectl create secret generic x --from-file=password=/dev/stdin
printf '%s\\n' "$P" | redis-cli --pass-stdin ping
curl -H @<(printf 'Cookie: %s\\n' "$JWE") https://x
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

TAINT = """\
P="$(kubectl get secret db -o jsonpath='{.data.password}' | base64 -d)"
U="$(kubectl get secret db -o jsonpath='{.data.user}' | base64 -d)"
S="$(kubectl get secret aws -o jsonpath='{.data.secret_key}' | base64 -d)"
T="$(kubectl get secret api -o jsonpath='{.data.token}' | base64 -d)"
SESSION="$(kubectl get secret s -o jsonpath='{.data.token}' | base64 -d)"
"""
BAD += [
    ('curl --header "Cookie: $JWE" https://x', "header argument"),
    ("curl -H 'Cookie: '\"$JWE\" https://x", "header argument"),
    (TAINT + 'curl -H "X-Auth: $SESSION" https://x', "header argument"),
    (TAINT + 'docker run --env "API_TOKEN=$T" img', "container environment"),
    ('docker exec -e"API_TOKEN=$TOKEN" c cmd', "container environment"),
    ('docker exec -e "DB_PW=$PW" c cmd', "container environment"),
    ('jq --argjson t "$TOKEN" \'{t:$t}\' <<<"{}"', "jq --arg"),
    (TAINT + 'curl -u admin:"$P" https://x', "(-u)"),
    (TAINT + 'redis-cli -a "$P" ping', "redis-cli"),
    (TAINT + 'mc alias set local http://m "$U" "$P"', "mc alias set"),
    (TAINT + 'psql --password "$P" -c x', "--password"),
    (TAINT + 'kubectl create secret generic s --from-literal=password="$P"', "--from-literal"),
    (TAINT + 'helm upgrade x y --set auth.password="$P"', "helm --set"),
    (TAINT + 'gh secret set X --body "$T"', "gh --body"),
    (TAINT + 'aws configure set aws_secret_access_key "$S"', "aws configure set"),
    # A copy of a sensitive variable keeps the secret, whatever its name.
    (TAINT + 'COPY="$P"\ncurl -u admin:"$COPY" https://x', "(-u)"),
    # Inside a command substitution and after kubectl exec --.
    (TAINT + 'OUT="$(curl -u admin:"$P" https://x)"', "(-u)"),
    (TAINT + 'kubectl exec pod -- redis-cli -a "$P" ping', "redis-cli"),
]
def selftest() -> int:
    got = findings(TAINT + GOOD, "good")
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
