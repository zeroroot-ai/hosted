# expect: 3
@test "a negation that is not last in a subshell" {
  ( ! grep -q hi "$BATS_TEST_TMPDIR/f"; echo x )
  echo after
}
