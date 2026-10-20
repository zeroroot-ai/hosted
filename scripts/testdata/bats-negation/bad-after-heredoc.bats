# expect: 6
@test "a bare negation after a heredoc stub" {
  cat > "$BATS_TEST_TMPDIR/stub" <<'SH'
  ! grep -qx a "$TMP/deleted"
SH
  ! grep -q hi "$BATS_TEST_TMPDIR/f"
  echo after
}
