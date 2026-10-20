# expect: none
@test "the last command of a subshell stops the test" {
  ( ! grep -q hi "$BATS_TEST_TMPDIR/f" )
  ( true; ! grep -q hi "$BATS_TEST_TMPDIR/f" )
}
@test "the last command of a command substitution stops the test" {
  x=$(true; ! grep -q hi "$BATS_TEST_TMPDIR/f")
}
@test "a handler that fails" {
  ! grep -q hi "$BATS_TEST_TMPDIR/f" || false
  ! grep -q hi "$BATS_TEST_TMPDIR/f" || exit 1
  ! grep -q hi "$BATS_TEST_TMPDIR/f" || { echo found; return 1; }
}
