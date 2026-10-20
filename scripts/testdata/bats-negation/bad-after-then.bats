# expect: 4
@test "a negation in the then branch" {
  if [ -f x ]; then
    ! grep -q hi "$BATS_TEST_TMPDIR/f"
  fi
}
