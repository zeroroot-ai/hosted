# expect: 3
@test "a negation after && is inert" {
  [ -f "$BATS_TEST_TMPDIR/f" ] && ! grep -q hi "$BATS_TEST_TMPDIR/f"
  echo after
}
