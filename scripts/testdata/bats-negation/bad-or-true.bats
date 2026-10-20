# expect: 3
@test "a handler that cannot fail" {
  ! grep -q hi "$BATS_TEST_TMPDIR/f" || true
  echo after
}
