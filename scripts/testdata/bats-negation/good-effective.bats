@test "run and status" {
  run grep -q hi "$BATS_TEST_TMPDIR/f"
  [ "$status" -ne 0 ]
}
@test "a handler runs when the negation fails" {
  ! grep -q hi "$BATS_TEST_TMPDIR/f" || { echo "found"; false; }
}
@test "a stub script is not a test body" {
  cat > "$BATS_TEST_TMPDIR/stub" <<'SH'
  ! grep -qx a "$TMP/deleted" 2>/dev/null || ua=a1
  ! grep -qx b "$TMP/deleted"
SH
  # ! grep -q x y
  [ -f "$BATS_TEST_TMPDIR/stub" ]
}
