#!/usr/bin/env python3
"""velero-backup-from-schedule.py — the Backup a Schedule tick would build.

Step 2 of a preserve teardown (scripts/teardown-kind.sh, deploy#1738). The
Velero server builds a cron tick's Backup from `spec.template` of the
Schedule, and the velero CLI's `--from-schedule` builds the same object
client-side. Doing it here with kubectl and this file means a teardown backs
up with the SHIPPED spec (helm/gibson-velero/templates/schedule.yaml) and
needs no velero CLI on a workstation or a runner.

This file does NOT re-check the spec it copies. The template is already
gated where it is authored: helm/gibson-velero/tests/lib/check_velero_schedule.py
asserts the `secrets` exclusion and the rest of the contract against the
render, with its own failing fixture in velero-schedule.bats. And a spec
that did ask for Secrets comes back PartiallyFailed, which the teardown
treats as a failure. A copy of that check here would be a third place to
keep in step, and would fail no earlier than the two that already exist.

Usage: velero-backup-from-schedule.py <backup-name> < <schedule.json>
Exit:  0 the Backup JSON on stdout
"""

from __future__ import annotations

import json
import sys

# The tag CONTEXT.md § Backup cadence names: this backup was taken by a
# preserve teardown, not by the hourly tick, so a human or a lifecycle rule
# can tell them apart. Retention itself is the bucket's lifecycle rule and
# nothing else.
PRESERVE_LABEL = "gibson.zeroroot.ai/preserve-teardown"


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    name = argv[1]
    schedule = json.load(sys.stdin)

    json.dump(
        {
            "apiVersion": "velero.io/v1",
            "kind": "Backup",
            "metadata": {
                "name": name,
                "namespace": schedule["metadata"]["namespace"],
                "labels": {
                    "velero.io/schedule-name": schedule["metadata"]["name"],
                    PRESERVE_LABEL: "true",
                },
            },
            "spec": schedule["spec"]["template"],
        },
        sys.stdout,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
