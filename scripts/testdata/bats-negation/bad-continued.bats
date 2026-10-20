# expect: 3
@test "a bare negation with a continuation" {
  ! grep -q \
    hi "$BATS_TEST_TMPDIR/f"
  echo after
}
