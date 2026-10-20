# expect: 3
@test "the word fail in an echo is no failing handler" {
  ! grep -q hi "$BATS_TEST_TMPDIR/f" || echo fail
  echo after
}
