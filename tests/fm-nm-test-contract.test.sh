#!/usr/bin/env bash
# Contract: parsed .no-mistakes.yaml must leave commands.test absent or empty.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"

test_nm_has_no_deterministic_test_command() {
  local val
  val=$(python3 - "$NM" <<'PYTHON'
import sys, yaml
with open(sys.argv[1]) as source:
    doc = yaml.safe_load(source) or {}
commands = doc.get("commands") or {}
value = commands.get("test") if isinstance(commands, dict) else None
print("" if value is None or value is False or value == "" else repr(value))
PYTHON
) || fail "failed to parse .no-mistakes.yaml as YAML (PyYAML required)"
  if [ -n "$val" ]; then
    fail "commands.test must be absent or empty so Test stays intent-targeted; got: $val"
  fi
  pass "no-mistakes does not configure commands.test"
}

test_nm_has_no_deterministic_test_command
