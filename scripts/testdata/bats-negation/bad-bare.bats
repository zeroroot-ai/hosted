# expect: 4
@test "a bare negation in the middle" {
  echo hi > "$BATS_TEST_TMPDIR/f"
  ! grep -q hi "$BATS_TEST_TMPDIR/f"
  echo after
}
