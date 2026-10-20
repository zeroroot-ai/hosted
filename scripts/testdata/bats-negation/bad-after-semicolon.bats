# expect: 3
@test "a negation after a semicolon" {
  true; ! grep -q hi "$BATS_TEST_TMPDIR/f"
  echo after
}
