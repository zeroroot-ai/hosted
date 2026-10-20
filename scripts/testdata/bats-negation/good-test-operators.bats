# expect: none
@test "! inside [[ ]] is an operator of the test" {
  [[ -n a && ! -e /nonexistent ]]
  [[ ! -e /nonexistent ]]
}
@test "exit and return with no code are effective handlers" {
  ! grep -q hi "$BATS_TEST_TMPDIR/f" || exit
  ! grep -q hi "$BATS_TEST_TMPDIR/f" || return
}
