#!/usr/bin/env bats
#
# charts-ref.bats: an exit test installs only chart code that a writer of
# zeroroot-ai/charts pushed (.github/actions/charts-ref/resolve.sh).
#
# The remote is a local repository under $BATS_TEST_TMPDIR. It holds a main
# branch, a second branch, a light tag, an annotated tag and a pull request
# ref whose commit no branch holds. No network.
#
# Run:
#   bats tests/harness/charts-ref.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
RESOLVE="$REPO_ROOT/.github/actions/charts-ref/resolve.sh"

setup() {
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.test GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.test
  R="$BATS_TEST_TMPDIR/charts"
  git init -q -b main "$R"
  git -C "$R" commit -q --allow-empty -m one
  MAIN1="$(git -C "$R" rev-parse HEAD)"
  git -C "$R" commit -q --allow-empty -m two
  MAIN2="$(git -C "$R" rev-parse HEAD)"
  git -C "$R" tag v0.1.0 "$MAIN1"
  git -C "$R" tag -a -m rel v0.2.0 "$MAIN2"
  git -C "$R" checkout -q -b feat/x
  git -C "$R" commit -q --allow-empty -m branch
  BRANCH="$(git -C "$R" rev-parse HEAD)"
  git -C "$R" checkout -q --detach main
  git -C "$R" commit -q --allow-empty -m fork
  FORK="$(git -C "$R" rev-parse HEAD)"
  git -C "$R" update-ref refs/pull/7/head "$FORK"
  git -C "$R" checkout -q main
  export CHARTS_REMOTE="$R"
}

@test "main resolves to the head of main" {
  run "$RESOLVE" main
  [ "$status" -eq 0 ]; [ "$output" = "$MAIN2" ]
}

@test "a branch resolves to its head, with or without refs/heads/" {
  run "$RESOLVE" feat/x
  [ "$status" -eq 0 ]; [ "$output" = "$BRANCH" ]
  run "$RESOLVE" refs/heads/feat/x
  [ "$status" -eq 0 ]; [ "$output" = "$BRANCH" ]
}

@test "a light tag and an annotated tag resolve to their commit" {
  run "$RESOLVE" v0.1.0
  [ "$status" -eq 0 ]; [ "$output" = "$MAIN1" ]
  run "$RESOLVE" refs/tags/v0.2.0
  [ "$status" -eq 0 ]; [ "$output" = "$MAIN2" ]
}

@test "a commit on main is accepted" {
  run "$RESOLVE" "$MAIN1"
  [ "$status" -eq 0 ]; [ "$output" = "$MAIN1" ]
}

@test "FAILING FIXTURE: a pull request ref is refused" {
  run "$RESOLVE" refs/pull/7/head
  [ "$status" -eq 1 ]; [[ "$output" == *"pull request ref"* ]]
  run "$RESOLVE" pull/7/merge
  [ "$status" -eq 1 ]
}

@test "FAILING FIXTURE: a commit that only a pull request ref holds is refused" {
  run "$RESOLVE" "$FORK"
  [ "$status" -eq 1 ]; [[ "$output" == *"not on the main branch"* ]]
}

@test "FAILING FIXTURE: a commit of another branch is refused by commit, not by name" {
  run "$RESOLVE" "$BRANCH"
  [ "$status" -eq 1 ]
}

@test "FAILING FIXTURE: an unknown name, an empty ref and an option are refused" {
  run "$RESOLVE" no-such-branch
  [ "$status" -eq 1 ]; [[ "$output" == *"is not a branch, a tag or a commit on main"* ]]
  run "$RESOLVE" ""
  [ "$status" -eq 1 ]
  run "$RESOLVE" "--upload-pack=touch $BATS_TEST_TMPDIR/pwned"
  [ "$status" -eq 1 ]; [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}
