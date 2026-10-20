# expect: 4
@test "a bare negation after a herestring" {
  grep -q a <<<word || true
  ! grep -q hi "$BATS_TEST_TMPDIR/f"
  echo after
}
