# Failing fixtures for scripts/check-verb-workflows.py

Every guard ships with a failing fixture (CLAUDE.md § Engineering rules).
Each bad file here breaks exactly one rule of the ADR-0083 verb-workflow
contract, and `check-verb-workflows.py --selftest` proves the guard rejects
it for that reason. `teardown-good.yml` is the minimal clean shape the
guard must accept. These files are fixtures, never workflows: they live
outside `.github/workflows/` and nothing dispatches them.
