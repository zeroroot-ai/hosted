# expect: 3
@test "a quoted || is not a handler" {
  ! grep -q "a||b" "$BATS_TEST_TMPDIR/f"
  echo after
}
