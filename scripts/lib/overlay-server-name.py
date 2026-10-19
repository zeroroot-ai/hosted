#!/usr/bin/env python3
"""overlay-server-name.py <values.yaml> <name> — the overlay with
platformPostgres.backup.serverName set to <name>, on stdout.

One line changes and every comment stays, because the overlay is a reviewed
file. The line is found by the value the YAML holds now, and it must be the
only serverName line with that value. An overlay with no serverName is
refused: this rewrites a line, it never invents a block.

Two writers use it: scripts/stamp-pg-archive.sh (a fresh archive name) and
the catch-up PR of a restore (scripts/lib/restore-recovery.sh, D91).
"""
import re
import sys

import yaml


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: overlay-server-name.py <values.yaml> <name>", file=sys.stderr)
        return 2
    path, new = sys.argv[1], sys.argv[2]
    src = open(path, encoding="utf-8").read()
    v = yaml.safe_load(src) or {}
    current = ((v.get("platformPostgres") or {}).get("backup") or {}).get("serverName")
    if not current:
        print("overlay-server-name: %s sets no platformPostgres.backup.serverName. Add `serverName: \"\"` "
              "under platformPostgres.backup first, so this rewrites a line rather than inventing a block"
              % path, file=sys.stderr)
        return 1
    pat = re.compile(r'^(\s*serverName:\s*)(["\']?)' + re.escape(str(current)) + r'\2(\s*(?:#.*)?)$', re.M)
    hits = pat.findall(src)
    if len(hits) != 1:
        print("overlay-server-name: %d serverName lines carry %r in %s; refusing to guess which one to rewrite"
              % (len(hits), current, path), file=sys.stderr)
        return 1
    sys.stdout.write(pat.sub(lambda m: '%s"%s"%s' % (m.group(1), new, m.group(3)), src, count=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
