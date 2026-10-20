# expect: 3
@test "a false after the handler is not its handler" {
  ! grep -q hi "$BATS_TEST_TMPDIR/f" || echo found; false
  echo after
}
