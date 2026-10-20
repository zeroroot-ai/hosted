# expect: 3
@test "a negation in a one-line case" {
  case a in a) ! grep -q hi "$BATS_TEST_TMPDIR/f" ;; esac
  echo after
}
