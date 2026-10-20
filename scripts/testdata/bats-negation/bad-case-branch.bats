# expect: 4
@test "a negation in a case branch" {
  case "$x" in
    a) ! grep -q hi "$BATS_TEST_TMPDIR/f" ;;
  esac
  echo after
}
