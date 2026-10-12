#!/usr/bin/env bash
# Contract tests for .github/workflows/ci.yml's runner-spend safeguards.
#
# Origin: the 2026-09-12 GitHub Actions starvation incident. firstmate CI had no
# concurrency deduplication, so every superseded PR head kept its full job
# fan-out, and four jobs carried no timeout at all. These tests hold both
# safeguards: PR runs supersede within one PR while main pushes are never
# cancelled, and every CI job carries a finite hang tripwire drawn from the
# three-tier timeout policy that docs/fm-test-portable-shards.md "Timeouts"
# owns (fast, normal, heavy), so no job drifts back to a one-off number.
#
# The workflow is parsed as YAML and its concurrency expressions are resolved
# against simulated pull_request and push contexts, so the assertions describe
# what GitHub would do, not how the file happens to be spelled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"

assert_present "$CI_WORKFLOW" ".github/workflows/ci.yml is missing"
python3 -c "import yaml" \
  || fail "PyYAML is required to parse .github/workflows/ci.yml as YAML"

# Resolve the workflow's concurrency contract under one simulated event and
# print "<group><TAB><cancel-in-progress>". Only the two expression constructs
# this workflow uses are resolved: an `a || b` fallback and an `==` comparison.
resolve_concurrency() {
  local event=$1 pr_number=$2 run_id=$3
  python3 - "$CI_WORKFLOW" "$event" "$pr_number" "$run_id" <<'PYTHON'
import re, sys, yaml
with open(sys.argv[1]) as source:
    doc = yaml.safe_load(source)
concurrency = doc["concurrency"]
context = {
    "github.workflow": doc["name"],
    "github.event_name": sys.argv[2],
    "github.event.pull_request.number": sys.argv[3],
    "github.run_id": sys.argv[4],
}
def value(token):
    token = token.strip()
    if token.startswith("\x27") and token.endswith("\x27"):
        return token[1:-1]
    return context[token]
def evaluate(expression):
    if "==" in expression:
        left, right = expression.split("==", 1)
        return str(value(left) == value(right)).lower()
    return next((value(token) for token in expression.split("||") if value(token)), "")
def interpolate(raw):
    return re.sub(r"\$\{\{(.+?)\}\}", lambda match: evaluate(match[1]), str(raw))
print("\t".join(interpolate(concurrency[key]) for key in ("group", "cancel-in-progress")))
PYTHON
}

job_timeout() {
  python3 - "$CI_WORKFLOW" "$1" <<'PYTHON'
import sys, yaml
with open(sys.argv[1]) as source:
    print(yaml.safe_load(source)["jobs"][sys.argv[2]].get("timeout-minutes", "none"))
PYTHON
}

# Tier membership is the executable inventory of the timeout policy: a new job
# must join a tier, and a job-level value outside these tiers is exactly the
# one-off number the policy removed.
FAST_TIER_JOBS='test-coverage invariants tests-timing-aggregate'
NORMAL_TIER_JOBS='lint tests-portable-parallel-1 tests-portable-parallel-2 tests-portable-serial macos-stock-bash'
HEAVY_TIER_JOBS='tests-herdr'

# Print the one timeout every listed job shares; fail on any disagreement.
tier_timeout() {  # <tier> <job>...
  local tier=$1 job first actual
  shift
  first=
  for job in "$@"; do
    actual=$(job_timeout "$job") || fail "could not read the $job timeout"
    case "$actual" in ''|*[!0-9]*) fail "$job ($tier tier) has no integer timeout, got $actual" ;; esac
    if [ -z "$first" ]; then
      first=$actual
    elif [ "$actual" != "$first" ]; then
      fail "$tier tier jobs must share one timeout, got $first and $actual ($job)"
    fi
  done
  printf '%s\n' "$first"
}

# Print every job id in the workflow, one per line.
workflow_jobs() {
  python3 - "$CI_WORKFLOW" <<'PYTHON'
import sys, yaml
with open(sys.argv[1]) as source:
    print("\n".join(yaml.safe_load(source)["jobs"]))
PYTHON
}

group_of() { printf '%s\n' "$1" | cut -f1; }
cancel_of() { printf '%s\n' "$1" | cut -f2; }

test_pr_pushes_supersede_within_one_pr() {
  local first second
  first=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  second=$(resolve_concurrency pull_request 108 900002) || fail "could not resolve PR concurrency"
  [ "$(group_of "$first")" = "$(group_of "$second")" ] \
    || fail "two runs of one PR must share a concurrency group, got $(group_of "$first") and $(group_of "$second")"
  [ "$(cancel_of "$first")" = true ] \
    || fail "PR runs must cancel the in-progress run, got $(cancel_of "$first")"
  pass "a newer push to one PR supersedes that PR's in-flight CI"
}

test_separate_prs_do_not_cancel_each_other() {
  local one two
  one=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  two=$(resolve_concurrency pull_request 109 900003) || fail "could not resolve PR concurrency"
  [ "$(group_of "$one")" != "$(group_of "$two")" ] \
    || fail "distinct PRs must not share a concurrency group ($(group_of "$one"))"
  pass "distinct PRs get distinct concurrency groups"
}

test_main_pushes_are_never_cancelled() {
  local first second
  first=$(resolve_concurrency push '' 900010) || fail "could not resolve push concurrency"
  second=$(resolve_concurrency push '' 900011) || fail "could not resolve push concurrency"
  [ "$(group_of "$first")" != "$(group_of "$second")" ] \
    || fail "each main push must get its own concurrency group, got $(group_of "$first") twice"
  [ "$(cancel_of "$first")" = false ] \
    || fail "push runs must never cancel an in-progress run, got $(cancel_of "$first")"
  pass "every main push keeps its own group and is never cancelled"
}

test_every_job_has_a_finite_timeout() {
  local reported
  reported=$(python3 - "$CI_WORKFLOW" <<'PYTHON'
import sys, yaml
with open(sys.argv[1]) as source:
    jobs = yaml.safe_load(source)["jobs"]
for name, job in jobs.items():
    timeout = job.get("timeout-minutes")
    if type(timeout) is not int or timeout <= 0:
        print(f"{name}: {timeout!r}")
PYTHON
) || fail "could not read job timeouts from ci.yml"
  [ -z "$reported" ] || fail "these CI jobs have no finite hang tripwire:"$'\n'"$reported"
  pass "every ci.yml job carries a finite timeout"
}

# Every job sits in exactly one tier, and the workflow carries exactly three
# distinct job-level timeouts: one per tier, no one-off numbers.
test_every_job_belongs_to_exactly_one_timeout_tier() {
  local expected actual distinct
  # shellcheck disable=SC2086
  expected=$(printf '%s\n' $FAST_TIER_JOBS $NORMAL_TIER_JOBS $HEAVY_TIER_JOBS | LC_ALL=C sort)
  [ "$(printf '%s\n' "$expected" | LC_ALL=C sort -u)" = "$expected" ] \
    || fail "a job is listed in more than one timeout tier:"$'\n'"$expected"
  actual=$(workflow_jobs | LC_ALL=C sort) || fail "could not list ci.yml jobs"
  [ "$actual" = "$expected" ] \
    || fail "ci.yml jobs and the timeout tiers disagree; every job must join one tier"$'\n'"workflow: $(printf '%s' "$actual" | tr '\n' ' ')"$'\n'"tiers: $(printf '%s' "$expected" | tr '\n' ' ')"
  distinct=$(for job in $expected; do job_timeout "$job"; done | LC_ALL=C sort -u | wc -l | tr -d ' ')
  [ "$distinct" = 3 ] \
    || fail "ci.yml must carry exactly three distinct job timeouts (fast, normal, heavy), got $distinct"
  pass "every ci.yml job belongs to one of the three timeout tiers"
}

# Fast tier: seconds-long checks share one short tripwire in the 5-10 minute band.
test_fast_tier_shares_one_short_tripwire() {
  local fast
  # shellcheck disable=SC2086
  fast=$(tier_timeout fast $FAST_TIER_JOBS) || exit 1
  [ "$fast" -ge 5 ] && [ "$fast" -le 10 ] \
    || fail "fast tier must be a 5-10 minute hang tripwire, got $fast"
  pass "fast tier jobs share one $fast minute tripwire"
}

# Normal tier: every test or lint lane shares ONE fixed 30-minute budget,
# above the fast tier. That budget is a hang tripwire, not a packing estimate.
test_normal_tier_shares_one_budget() {
  local fast normal
  # shellcheck disable=SC2086
  fast=$(tier_timeout fast $FAST_TIER_JOBS) || exit 1
  # shellcheck disable=SC2086
  normal=$(tier_timeout normal $NORMAL_TIER_JOBS) || exit 1
  [ "$normal" -gt "$fast" ] \
    || fail "normal tier ($normal) must exceed the fast tier ($fast)"
  [ "$normal" = 30 ] \
    || fail "normal tier must be the single 30-minute shared budget, got $normal"
  pass "normal tier jobs share one $normal minute budget"
}

# Heavy tier: Herdr alone carries a job-level last-resort backstop above the
# normal tier, while its family-run step owns a tighter tripwire so the
# always() cleanup and timing upload still run after a hang.
test_heavy_tier_keeps_a_step_tripwire_under_a_job_backstop() {
  local normal heavy step
  # shellcheck disable=SC2086
  normal=$(tier_timeout normal $NORMAL_TIER_JOBS) || exit 1
  # shellcheck disable=SC2086
  heavy=$(tier_timeout heavy $HEAVY_TIER_JOBS) || exit 1
  [ "$heavy" -gt "$normal" ] \
    || fail "heavy tier backstop ($heavy) must exceed the normal tier ($normal)"
  [ "$heavy" -ge 60 ] && [ "$heavy" -le 75 ] \
    || fail "heavy tier backstop must stay a 60-75 minute last resort, got $heavy"
  step=$(python3 - "$CI_WORKFLOW" tests-herdr <<'PYTHON'
import sys, yaml
with open(sys.argv[1]) as source:
    steps = yaml.safe_load(source)["jobs"][sys.argv[2]]["steps"]
index = next(i for i, step in enumerate(steps) if step.get("id") == "run-real-herdr-family")
teardown = next(i for i, step in enumerate(steps) if step.get("id") == "cleanup-herdr-lab-sessions")
assert teardown > index, "teardown must follow the family-run step"
assert steps[teardown]["if"].strip() == "always()", "teardown must run under always()"
print(steps[index].get("timeout-minutes", "none"))
PYTHON
) || fail "could not read the Herdr family-run step"
  case "$step" in ''|*[!0-9]*) fail "the Herdr family-run step needs its own timeout-minutes, got $step" ;; esac
  [ "$step" = 20 ] \
    || fail "the Herdr family-run step must be the 20-minute tripwire, got $step"
  [ "$step" -lt "$heavy" ] \
    || fail "the Herdr step tripwire ($step) must stay below the job backstop ($heavy)"
  pass "Herdr keeps a $step minute step tripwire under a $heavy minute job backstop"
}

test_ci_matrices_match_executable_partitions() {
  python3 - "$CI_WORKFLOW" "$ROOT" <<'PYTHON' || fail "CI partition contract"
import os, re, subprocess, sys, yaml
with open(sys.argv[1]) as source:
    jobs = yaml.safe_load(source)["jobs"]
root = sys.argv[2]
serial = jobs["tests-portable-serial"]["strategy"]
assert serial["fail-fast"] is False, "serial failures must not cancel other shards"
matrix = serial["matrix"]
assert list(matrix) == ["shard"], "unexpected serial dimensions"
shards = matrix["shard"]
def run(script, *args, **kwargs):
    return subprocess.check_output([os.path.join(root, "bin", script), *args], text=True, **kwargs).splitlines()
lanes = run("fm-test-run.sh", "--list-lanes")
actual = [lane.strip() for lane in lanes if re.fullmatch(r"portable-serial-\d+of\d+", lane.strip())]
expected = [f"portable-serial-{shard}of{len(shards)}" for shard in shards]
assert sorted(actual) == sorted(expected), "CI matrix and runner disagree"
lint = jobs["lint"]["strategy"]
assert lint["fail-fast"] is False, "lint failures must not cancel another partition"
matrix = lint["matrix"]
assert list(matrix) == ["partition"], "unexpected lint dimensions"
parts = matrix["partition"]
roots = [line.strip() for part in parts for line in run("fm-lint.sh", "--partition", f"{part}of{len(parts)}", "--list-files")]
canonical = run("fm-lint.sh", "--list-files", env={**os.environ, "CI": "true"})
assert sorted(roots) == sorted(line.strip() for line in canonical), "lint matrix loses or duplicates canonical roots"
PYTHON
  pass "CI matrices cover every executable serial lane and canonical lint root exactly once"
}

test_ci_matrices_match_executable_partitions
test_pr_pushes_supersede_within_one_pr
test_separate_prs_do_not_cancel_each_other
test_main_pushes_are_never_cancelled
test_every_job_has_a_finite_timeout
test_every_job_belongs_to_exactly_one_timeout_tier
test_fast_tier_shares_one_short_tripwire
test_normal_tier_shares_one_budget
test_heavy_tier_keeps_a_step_tripwire_under_a_job_backstop
