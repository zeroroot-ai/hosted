#!/usr/bin/env python3
"""check-stub-names.py: a bats stub of kubectl answers only the object names
its test declares (hosted#654).

Three times a stub answered yes to any object name. The script under test
read a name that did not exist, and the test still passed (hosted#645,
hosted#653). A stub that accepts any name cannot fail on a wrong name.

What fails, keyed by content, in each kubectl stub that a tests/harness/*.bats
file writes (`cat > ".../kubectl" <<'X'` ... `X`):

  1. The stub has no fallback branch `*) ... exit <non-zero>`, so an
     undeclared call answers with exit 0.
  2. A branch whose pattern reads an object with a wildcard name, for example
     `*"get secret "*)` or `*"get pods"*)` for a named read, answers with exit
     0. A wildcard is allowed only for an answer that a real cluster gives to
     a name that does not exist (an error exit).

The aws and terraform stubs (rows 39 to 41 of the drill path sweep) answer
queries by shape on purpose: a count, an empty list, an outage. For them the
rule is the named one: an aws operation on ONE resource (s3 rm/cp/mv, an
s3api object call, a secret value, an access key, a zone change) whose
pattern names no bucket, key, secret or id, and whose branch answers it. A
terraform stub runs on the state of its test and has no names to declare.
Every stub write must be read: the scan fails when it reads fewer stub
bodies than the files write.

Usage:  scripts/check-stub-names.py [--selftest]
Exit:   0 clean, 1 a stub breaks a rule, 2 the self-test is broken or no stub was found
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOOLS = "kubectl|aws|terraform"
HEREDOC = re.compile(r'cat\s*>\s*"?[^"\n]*/(' + TOOLS + r')"?\s*<<-?\s*[\'"]?(\w+)[\'"]?\n(.*?)\n\2\n', re.S)
BRANCH = re.compile(r'^\s*([^\n()]*?)\)\s*(.*?);;', re.M | re.S)
# A read of one object by a wildcard name: the kind, then a space or a slash
# where the name goes, then the pattern ends. A list (`get pods -o json`)
# names no object and is not a named read.
WILD_READ = re.compile(r'\b(get|wait|describe)\s+(?:-n\s+\S+\s+)?([a-z][\w.\-]*)(?:\s|/)$')


# An aws call that names no resource: the service and the operation, then the
# pattern ends, so any bucket, key, secret or user answers (`"s3 rm")`).
AWS_ANY = re.compile(r'^(s3|s3api|secretsmanager|iam|route53)\s+'
                     r'(rm|cp|mv|get-object|put-object|delete-object|head-object|list-objects-v2|'
                     r'get-secret-value|put-secret-value|get-access-key-last-used|list-access-keys|'
                     r'create-access-key|delete-access-key|change-resource-record-sets)\s*$')


def _segments(body: str):
    """Each top-level branch of the stub: its pattern and its whole body, up to
    the next pattern at the same indent or the `esac`. A nested case inside a
    branch stays in its body."""
    lines = body.splitlines()
    starts = [i for i, l in enumerate(lines) if re.match(r'^  ["*][^\n]*\)', l)]
    for k, i in enumerate(starts):
        end = starts[k + 1] if k + 1 < len(starts) else len(lines)
        for j in range(i + 1, end):
            if lines[j].startswith("esac"):
                end = j
                break
        head = lines[i]
        pattern = head[:head.index(")")].strip() if ")" in head else head.strip()
        yield pattern, "\n".join([head[head.index(")") + 1:]] + lines[i + 1:end])


def _named_any(body: str, where: str, tool: str) -> list[str]:
    out = []
    if tool != "aws":
        return out
    for pattern, action in _segments(body):
        for alt in pattern.split("|"):
            alt = alt.strip()
            m = AWS_ANY.search(alt.strip("*").strip('"').strip())
            # A branch that refuses an undeclared resource in its body (an
            # exit that is not zero) names its resource there.
            if m and not re.search(r"exit\s+[1-9]", action):
                out.append(f"{where}: `{alt})` runs aws {m.group(1)} {m.group(2)} on any resource and answers it")
    return out


def stub_findings(body: str, where: str, tool: str = "kubectl") -> list[str]:
    out = []
    if tool != "kubectl":
        # aws and terraform stubs answer queries by shape on purpose (a count,
        # an empty list, an outage). The defect class of hosted#654 for them is
        # an operation on ONE resource (a bucket and key, a secret, an access
        # key, a zone change) that answers whatever resource it is given.
        return _named_any(body, where, tool)
    code = [l.strip() for l in body.splitlines() if l.strip() and not l.strip().startswith("#")]
    if code and all(re.fullmatch(r"(echo [^;]*>&2;?\s*)?exit\s+[1-9]", l) or l.startswith("echo ") and l.endswith(">&2") for l in code) \
            and re.fullmatch(r"(.*;\s*)?exit\s+[1-9]", code[-1]):
        return []  # a stub that fails every call answers no name
    if "case " not in body:
        return [f"{where}: the stub has no case on its arguments, so it answers every call"]
    branches = BRANCH.findall(body)
    fallback = [b for p, b in branches if p.strip() == "*"]
    # The fallback is a `*)` branch that exits non-zero, or the first lines
    # after `esac` that end in a non-zero exit.
    after = body.rsplit("esac", 1)[-1].strip().splitlines()[:3]
    strict_after = any(re.match(r"(.*;\s*)?exit\s+[1-9]", l.strip()) for l in after)
    if not (fallback and re.search(r"exit\s+[1-9]", fallback[-1])) and not strict_after:
        out.append(f"{where}: no fallback `*) ... exit 1`, so an undeclared call answers exit 0")
    for pattern, action in branches:
        for alt in pattern.split("|"):
            alt = alt.strip()
            if alt == "*" or not alt.endswith("*"):
                continue
            m = WILD_READ.search(alt.strip('*').strip('"')) if tool == "kubectl" else AWS_ANY.search(alt.strip('*').strip('"')) if tool == "aws" else None
            if m and not re.search(r"exit\s+[1-9]", action):
                out.append(f"{where}: `{alt})` reads a {m.group(2)} by any name and answers it")
    return out


# A helper function whose body writes its stdin to the kubectl stub, and the
# heredocs that the tests feed to it: `write_kubectl_stub <<'SH' ... SH`.
HELPER = re.compile(r'^\s*(\w+)\(\)\s*\{\s*\n\s*cat\s*>\s*"?[^"\n]*/(' + TOOLS + r')"?\s*\n', re.M)
# Every write of a kubectl stub, whatever its form. The scan must find a body
# for each, or it saw less than the files hold.
WRITES = re.compile(r'(?:cat|printf[^\n]*?)\s*>\s*"?\$\{?(?:STUB_DIR|STUBS|BIN|TMP|AWS_STUBS|WORK|D)\}?(?:/bin)?/(?:' + TOOLS + r')(?:"|\s|$)', re.M)
ONE_LINE = re.compile(r"printf\s+'([^']*)'[^>\n]*>\s*\"?[^\"\n]*/(" + TOOLS + r")(?:\"|\s|$)", re.M)


def file_findings(text: str, name: str) -> tuple[int, list[str]]:
    found = [(tool, body) for tool, _tag, body in HEREDOC.findall(text)]
    for fn, tool in HELPER.findall(text):
        found += [(tool, m.group(2)) for m in re.finditer(rf'\b{fn}\s*<<-?\s*[\'"]?(\w+)[\'"]?\n(.*?)\n\1\n', text, re.S)]
    out = []
    stubs = []
    for i, (tool, body) in enumerate(found, 1):
        out += stub_findings(body, f"{name} {tool} stub {i}", tool)
        stubs.append(body)
    # A one-line stub that always exits non-zero answers nothing: strict.
    for m in ONE_LINE.finditer(text):
        if m.group(2) == "kubectl" and not re.search(r"exit\s+[1-9]", m.group(1)):
            out.append(f"{name}: the one-line kubectl stub `{m.group(0)[:60]}` answers every call")
        stubs.append(m.group(1))
    writes = len(WRITES.findall(text)) - len(HELPER.findall(text))
    if len(stubs) < writes:
        out.append(f"{name}: {writes} stub writes, and the scan read {len(stubs)} stub bodies. A stub the scan cannot read is not checked")
    return len(stubs), out


GOOD = """cat > "$BIN/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"get secret gibson-billing-stripe -o jsonpath={.data.K}"*) printf x; exit 0 ;;
  *"get secret "*) echo "Error from server (NotFound)" >&2; exit 1 ;;
  *"get pods -o json"*) echo '{"items": []}' ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
cat > "$BIN/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "get secret x -o json") echo '{}'; exit 0 ;;
esac
echo "kubectl stub: undeclared call: $*" >&2; exit 1
SH
"""
BAD = [
    (GOOD.replace('  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;\n', ""), "no fallback"),
    (GOOD.replace('exit 1 ;;\nesac', 'exit 0 ;;\nesac'), "no fallback"),
    (GOOD.replace('echo "Error from server (NotFound)" >&2; exit 1', 'printf yes'), "reads a secret by any name"),
    (GOOD.replace('*"get secret "*)', '*"get backup.velero.io/"*)').replace('echo "Error from server (NotFound)" >&2; exit 1', 'echo x'),
     "reads a backup.velero.io by any name"),
    ('cat > "$BIN/kubectl" <<\'SH\'\n#!/usr/bin/env bash\necho ok\nSH\n', "no case"),
    ('w() {\n  cat > "$B/kubectl"\n  chmod +x "$B/kubectl"\n}\nw <<\'SH\'\n#!/usr/bin/env bash\necho ok\nSH\n', "no case"),
    ("printf '#!/usr/bin/env bash\\necho ok\\n' > \"$B/kubectl\"\n", "answers every call"),
    ('cat > "$BIN/kubectl" < "$F"\n', "the scan read 0 stub bodies"),
    ('cat > "$BIN/aws" <<\'SH\'\n#!/usr/bin/env bash\ncase "$1 $2" in\n  "s3 rm") exit 0 ;;\nesac\nexit 1\nSH\n', "runs aws s3 rm on any resource"),
    ('cat > "$BIN/aws" <<\'SH\'\n#!/usr/bin/env bash\ncase "$1 $2" in\n  "s3api list-objects-v2")\n'
     '    while [ $# -gt 0 ]; do case "$1" in --bucket) b="$2"; shift 2 ;; *) shift ;; esac; done\n'
     '    echo 0 ;;\nesac\nexit 1\nSH\n', "runs aws s3api list-objects-v2 on any resource"),
]
# A branch that checks its bucket in its body, after a nested case, passes.
GOOD_AWS = ('cat > "$BIN/aws" <<\'SH\'\n#!/usr/bin/env bash\ncase "$1 $2" in\n  "s3api list-objects-v2")\n'
            '    while [ $# -gt 0 ]; do case "$1" in --bucket) b="$2"; shift 2 ;; *) shift ;; esac; done\n'
            '    [ "$b" = "$WANT" ] || { echo "NoSuchBucket" >&2; exit 254; }\n    echo 0 ;;\nesac\nexit 1\nSH\n')


def selftest() -> int:
    if file_findings(GOOD_AWS, "good")[1]:
        print(f"check-stub-names: selftest: an aws branch that checks its bucket failed: {file_findings(GOOD_AWS, 'good')[1]}", file=sys.stderr)
        return 2
    n, got = file_findings(GOOD, "good")
    if n != 2 or got:
        print(f"check-stub-names: selftest: the good stub failed ({n} stubs): {got}", file=sys.stderr)
        return 2
    for text, want in BAD:
        _, got = file_findings(text, "bad")
        if not any(want in g for g in got):
            print(f"check-stub-names: selftest: a bad stub did not raise {want!r}: {got}", file=sys.stderr)
            return 2
    print(f"✅ self-test: {len(BAD)} bad stubs each raise their rule; a stub that declares its names passes")
    return 0


def main() -> int:
    if "--selftest" in sys.argv[1:]:
        return selftest()
    total, got = 0, []
    for f in sorted((ROOT / "tests" / "harness").glob("*.bats")):
        n, found = file_findings(f.read_text(encoding="utf-8"), f.relative_to(ROOT).as_posix())
        total += n
        got += found
    if total == 0:
        print("check-stub-names: no kubectl stub found, so the scan saw nothing", file=sys.stderr)
        return 2
    if got:
        print("check-stub-names: a stub answers a name its test did not declare:", *got, sep="\n  ", file=sys.stderr)
        return 1
    print(f"✅ {total} kubectl, aws and terraform stubs answer only the names their tests declare")
    return 0


if __name__ == "__main__":
    sys.exit(main())
