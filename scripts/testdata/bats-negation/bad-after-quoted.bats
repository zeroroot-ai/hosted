# expect: 5
@test "a bare negation after text that looks like a heredoc" {
  [[ "$output" == *"<<EOF"* ]] || true
  n=$(( 1 <<x ))
  ! grep -q hi "$BATS_TEST_TMPDIR/f"
  echo after
}
