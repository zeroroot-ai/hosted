# expect: 3
@test "a negation in a brace group" {
  { ! grep -q hi "$BATS_TEST_TMPDIR/f"; }
  echo after
}
