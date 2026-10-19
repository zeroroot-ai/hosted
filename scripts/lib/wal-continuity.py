#!/usr/bin/env python3
"""wal-continuity.py — is the CNPG WAL archive continuous? (deploy#1738)

Check 2 of scripts/backup-verify.sh, the gate inside a preserve teardown
(ADR-0083, CONTEXT.md § Backup-verify). A base backup with a broken WAL
archive restores only to the instant it was taken, and it looks healthy the
whole time: the Backup CR says `completed`, the objects are in the bucket,
and the hole only surfaces when somebody replays.

A WAL segment file is named timeline(8) + logid(8) + segno(8) in upper-case
hex, optionally with a compression suffix barman appends. With the default
16 MiB segment size the segments of one timeline form the unbroken integer
sequence `logid * 256 + segno`. So continuity is arithmetic: take every
segment on the base backup's timeline, and require no missing index between
the backup's own beginWal and the newest archived segment.

Segments older than the backup are NOT required. The bucket lifecycle rule
expires old objects on its own schedule, and a backup only ever needs the
window from its own start forward.

Usage: wal-continuity.py <aws-s3-ls-output> <beginWal> <endWal>
       beginWal and endWal may be empty; then the oldest archived segment on
       the newest timeline stands in for beginWal.
Exit:  0 continuous, one summary line on stdout
       1 a gap, or nothing archived; the reason on stderr
"""

from __future__ import annotations

import os
import re
import sys

SEGMENT = re.compile(r"^[0-9A-F]{24}$")
COMPRESSION = (".gz", ".zst", ".lz4", ".snappy", ".bz2", ".xz")


def segment_index(name: str) -> int:
    """The position of a segment in its timeline's sequence."""
    return int(name[8:16], 16) * 0x100 + int(name[16:24], 16)


def parse(listing: str) -> set[str]:
    """Every WAL segment name in `aws s3 ls --recursive` output."""
    names: set[str] = set()
    with open(listing) as handle:
        for line in handle:
            parts = line.split()
            if not parts:
                continue
            name = os.path.basename(parts[-1])
            for suffix in COMPRESSION:
                if name.endswith(suffix):
                    name = name[: -len(suffix)]
                    break
            if SEGMENT.match(name):
                names.add(name)
    return names


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    listing, begin_wal, end_wal = argv[1], argv[2], argv[3]

    names = parse(listing)
    if not names:
        print(
            "no WAL segment is archived at all: archive_command is not shipping, "
            "so the base backup can replay nothing",
            file=sys.stderr,
        )
        return 1

    timeline = begin_wal[:8] if SEGMENT.match(begin_wal) else max(n[:8] for n in names)
    on_timeline = sorted(n for n in names if n[:8] == timeline)
    if not on_timeline:
        print(
            f"no WAL segment on timeline {timeline}, the timeline the base backup was taken on",
            file=sys.stderr,
        )
        return 1

    for label, wal in (("beginWal", begin_wal), ("endWal", end_wal)):
        if wal and wal not in names:
            print(
                f"the base backup's {label} {wal} is NOT archived: "
                "the backup cannot replay even its own window",
                file=sys.stderr,
            )
            return 1

    first = segment_index(begin_wal) if begin_wal in names else segment_index(on_timeline[0])
    present = {segment_index(n) for n in on_timeline}
    last = max(present)
    missing = [i for i in range(first, last + 1) if i not in present]
    if missing:
        print(
            f"the WAL archive has {len(missing)} gap(s) between the base backup and the "
            f"newest segment on timeline {timeline}, the first at segment index "
            f"0x{missing[0]:X}: recovery stops at the hole",
            file=sys.stderr,
        )
        return 1

    print(
        f"the WAL archive is continuous over {last - first + 1} segment(s) on timeline "
        f"{timeline}, from {begin_wal or on_timeline[0]} to the newest segment"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
