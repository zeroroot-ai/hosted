#!/usr/bin/env python3
"""check-bats-negation.py: no bats test asserts with a bare `! command`.

Bash does not stop on a failed `! command`, whatever `set -e` says. So a line
`! grep -q x file` in the middle of a bats test never fails the test. Only the
last command of the test counts. Twelve such lines read as checks and checked
nothing (hosted#12 review). The effective forms are:

    run grep -q x file
    [ "$status" -ne 0 ]

or `! command || { echo why; false; }`, which runs the handler when the
negation fails.

A `!` is effective in two cases only: a handler after it that can fail
(`|| false`, `|| exit 1`, `|| { ...; return 1; }`), and the last command of a
subshell or command substitution (`( ! cmd )`, `x=$(true; ! cmd)`), where the
non-zero status of the group stops the test. `&&` does not help, and neither
does `|| true`. A `!` after `&&` or in a case branch is as inert as one alone.

The scan skips the bodies of heredocs, because a stub script written by a
test is not run by bats. A herestring (`<<<`), a shift (`$(( 1 <<x ))`) and
text inside a quoted string are not heredocs. A heredoc whose terminator never
appears is a finding, because it would hide every later line. A statement that carries `||` or `&&`, and a
condition of `if`, `while` or `until`, are not bare.

Usage:  scripts/check-bats-negation.py [--selftest]
Exit:   0 clean, 1 a bare negation, 2 the self-test is broken or no file was read
The fixtures are in scripts/testdata/bats-negation/.
"""
from __future__ import annotations

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "scripts" / "testdata" / "bats-negation"
# A heredoc start: `<<` or `<<-`, then a word. Not `<<<` (a herestring), not
# `$(( 1 <<x ))` (a shift), and not text inside a quoted string or a comment.
HEREDOC = re.compile(r"<<(?![<(])-?\s*\\?['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?")
BARE = re.compile(r"^!\s+\S")
LEAD = re.compile(r"^(?:[{(]\s*|(?:then|do|else)\s+)+")


def mask(line: str) -> str:
    """The line with the text of each quoted string and the trailing comment
    blanked, so an operator is found only where the shell reads one. The
    length stays, so a position in the mask is a position in the line."""
    out, quote, i = [], "", 0
    while i < len(line):
        c = line[i]
        if quote:
            if quote == '"' and c == "\\":
                out.append("  "); i += 2; continue
            if c == quote:
                quote = ""
                out.append(c)
            else:
                out.append(" ")
        elif c in "\"'":
            quote = c
            out.append(c)
        elif c == "#" and (i == 0 or line[i - 1] in " \t;"):
            out.append(" " * (len(line) - i))
            break
        else:
            out.append(c)
        i += 1
    return "".join(out)


def heredoc_start(line: str):
    masked = mask(line)
    for m in re.finditer(r"(?<!<)<<(?![<(])", masked):
        before = masked[: m.start()]
        if before.count("((") > before.count("))"):
            continue
        d = HEREDOC.match(line, m.start())
        if d:
            return d
    return None


# A handler after `||` that can fail the test: false, exit, return 1, or a
# call that dies. `|| true` or `|| echo ...` lets the test go on, so the
# negation stays inert.
FAILING_HANDLER = re.compile(r"\|\|(?=.*\b(?:false|exit\s+[1-9]\d*|return\s+[1-9]\d*|die|fail)\b)")
CASE_LABEL = re.compile(r"^[^\s()]+\)\s*(?=!)")


def bare_negation(line: str) -> bool:
    """True when a statement of the line starts with `!` and cannot fail the
    test. Statements are split at `;` and `&&`. A `{`, `(`, `then`, `do`, `else`
    or a case label before the `!` is skipped. An `if` or `while` condition is
    not a statement of this kind. The `!` is effective in two cases only: a
    handler after it that fails (`|| false`, `|| { ...; false; }`, `|| exit 1`),
    and the last command of a subshell or a command substitution, where the
    non-zero status of the group stops the test. `&&` does not help, and
    neither does `|| true`: bash never stops for an inverted status."""
    masked = mask(line)
    bounds = [0] + [m.end() for m in re.finditer(r";|&&", masked)]
    for i, start in enumerate(bounds):
        end = bounds[i + 1] - 1 if i + 1 < len(bounds) else len(masked)
        seg = LEAD.sub("", masked[start:end].strip())
        seg = CASE_LABEL.sub("", seg)
        if not BARE.match(seg):
            continue
        # The handler may run on past the next `;` ( `|| { echo x; false; }` ).
        if "||" in seg and FAILING_HANDLER.search(masked[start:]):
            continue
        if seg.count(")") > seg.count("("):
            continue  # the last command of ( ... ) or $( ... )
        return True
    return False


def findings_at(path: pathlib.Path) -> list[tuple[int, str]]:
    lines = path.read_text(encoding="utf-8", errors="replace").split("\n")
    out, i = [], 0
    while i < len(lines):
        start, logical = i + 1, lines[i]
        while logical.rstrip().endswith("\\") and i + 1 < len(lines):
            i += 1
            logical = logical.rstrip()[:-1] + " " + lines[i].strip()
        i += 1
        if logical.lstrip().startswith("#"):
            continue
        if bare_negation(logical):
            out.append((start, logical.strip()[:100]))
        m = heredoc_start(logical)
        if not m:
            continue
        # Skip the body only when its terminator line really appears. A start
        # with no terminator hides every later line, so it is a finding.
        end = next((j for j in range(i, len(lines)) if lines[j].strip() == m.group(1)), None)
        if end is None:
            out.append((start, f"a heredoc with terminator {m.group(1)} that never ends, so the scan cannot see the lines after it"))
        else:
            i = end + 1
    return out


def findings(path: pathlib.Path) -> list[str]:
    return [f"{path.name}:{n}: {t}" for n, t in findings_at(path)]


def tracked_bats() -> list[pathlib.Path]:
    """Each tracked .bats file, the fixtures of this guard excepted."""
    try:
        names = subprocess.run(["git", "ls-files", "*.bats"], cwd=ROOT, capture_output=True,
                               text=True, check=True).stdout.split()
    except (OSError, subprocess.CalledProcessError):
        names = [str(p.relative_to(ROOT)) for p in ROOT.rglob("*.bats")]
    return sorted(ROOT / n for n in names if not n.startswith("scripts/testdata/"))


def expected_lines(path: pathlib.Path):
    """The lines a fixture must raise, from its first line: `# expect: 4,9`,
    or `# expect: none`."""
    first = path.read_text(encoding="utf-8").split("\n", 1)[0]
    m = re.match(r"#\s*expect:\s*(none|[0-9,\s]+)$", first)
    if not m:
        return None
    return [] if m.group(1) == "none" else [int(x) for x in m.group(1).split(",")]


def selftest() -> int:
    bads = sorted(FIXTURES.glob("bad-*.bats"))
    goods = sorted(FIXTURES.glob("good-*.bats"))
    if len(bads) < 13 or not goods:
        print("check-bats-negation: selftest: the fixtures are missing", file=sys.stderr)
        return 2
    for f in bads + goods:
        want = expected_lines(f)
        if want is None or (f in bads) == (want == []):
            print(f"check-bats-negation: selftest: {f.name} has no usable `# expect:` line", file=sys.stderr)
            return 2
        got = [n for n, _ in findings_at(f)]
        if got != want:
            print(f"check-bats-negation: selftest: {f.name} raised lines {got}, want {want}", file=sys.stderr)
            return 2
    print(f"✅ self-test: {len(bads)} bare negations are refused at the lines they name, {len(goods)} effective forms pass")
    return 0


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return selftest()
    paths = tracked_bats()
    if len(paths) < 10:
        print("check-bats-negation: fewer than 10 bats files were read", file=sys.stderr)
        return 2
    bad = [f for p in paths for f in findings(p)]
    if bad:
        print("❌ a bare `! command` never fails a bats test. Use `run command` and check $status:", file=sys.stderr)
        for b in bad:
            print(f"   {b}", file=sys.stderr)
        return 1
    print(f"✅ {len(paths)} bats files, no bare negation")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
