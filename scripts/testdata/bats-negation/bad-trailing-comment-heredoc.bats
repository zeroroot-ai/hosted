# expect: 4
@test "a trailing comment that looks like a heredoc hides nothing" {
  echo hi # cat <<EOF
  ! grep -q hi "$BATS_TEST_TMPDIR/f"
  echo after
}
