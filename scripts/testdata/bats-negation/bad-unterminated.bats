# expect: 3
@test "a heredoc that never ends" {
  cat <<EOF
  text
}
