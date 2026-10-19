# assert.bash — output assertions that say what they actually got.
#
# WHY THIS EXISTS
#
# A bats assertion written as
#
#     [[ "$output" == *"some phrase"* ]]
#
# prints NOTHING when it fails. bats reports the file, the line and the
# expression, and not one character of what the command actually said. On a
# workstation that is a minor annoyance, because the test is one command away.
# In CI it is the difference between a diagnosis and a guess.
#
# It cost a real one. `ci` on main failed on teardown.bats fixture 18 (run
# 35009552036, 2026-09-15). The test passed locally on the same commit and
# every prior run on main was green, so it was a flake — but which flake could
# not be determined, because the assertion printed no output and the run could
# not be reproduced. A whole CI failure with nothing to read.
#
# So: assert on output through these, and a failure carries its own evidence.
#
#   assert_output_has "some phrase"
#   refute_output_has "some phrase"
#
# There were 260 bare assertions across tests/harness when this was written.
# teardown.bats is converted; the rest adopt it as they are touched.

# assert_output_has <substring> — $output must contain it, and the failure
# prints the whole of what was actually produced.
assert_output_has() {
  local want="$1"
  if [[ "$output" != *"$want"* ]]; then
    printf 'expected the output to contain:\n  %s\nand it did not. The output was:\n' "$want" >&2
    printf '%s\n' "$output" | sed 's/^/  | /' >&2
    return 1
  fi
}

# refute_output_has <substring> — $output must NOT contain it.
refute_output_has() {
  local unwanted="$1"
  if [[ "$output" == *"$unwanted"* ]]; then
    printf 'expected the output NOT to contain:\n  %s\nand it did. The output was:\n' "$unwanted" >&2
    printf '%s\n' "$output" | sed 's/^/  | /' >&2
    return 1
  fi
}
