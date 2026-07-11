#!/usr/bin/env bash
#
# date/mayhem/test.sh — RUN date's functional oracle (date_behavior_checker) and the tz-free
# unit-test suite built by mayhem/build.sh, then emit a CTRF summary.
#
# REWARD-HACK-PROOF oracle design:
#   - date_behavior_checker calls date::parse() + date::format() with hard-coded inputs and
#     PRINTS each key=value result line to stdout.  We capture that output and grep for every
#     expected value.  When the program is neutered to exit(0) (the sabotage probe), nothing
#     is printed — the grep fails — so the oracle correctly reports failure.
#   - The tz-free *.pass.cpp suite uses assert() internally; if the checker DOES print correctly
#     (i.e., the library is functional), then the assert-based tests are redundant but additive
#     coverage.  We count both, but the checker is the primary guard.
#
# This script RUNS only — it never compiles. build.sh must have been run first.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

SRC_DIR="${SRC:-$(cd "$(dirname "$0")/.." && pwd)}"
BUILDDIR="$SRC_DIR/mayhem-tests"
CHECKER="$SRC_DIR/mayhem/date_behavior_checker"
# build.sh puts checker in $OUT (/mayhem or the OUT env); accept either location.
[ -x "$CHECKER" ] || CHECKER="${OUT:-/mayhem}/date_behavior_checker"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC_DIR/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PASSED=0; FAILED=0

# ── 1) Behavioral checker: parse + format known-answer verification ───────────────────────────
# REQUIRED: the checker must be present; its absence is itself a failure.
if [ ! -x "$CHECKER" ]; then
  echo "MISSING: $CHECKER — run mayhem/build.sh first" >&2
  emit_ctrf "date-oracle" 0 1 0; exit 2
fi

# Run the checker and capture stdout.  If the binary is neutered to exit(0), it prints nothing
# and the greps below fail — this is the anti-reward-hack gate.
checker_out="$("$CHECKER" 2>/dev/null)" || checker_rc=$?
checker_rc="${checker_rc:-0}"

# Each expected key=value pair that the behavioral checker must print.
declare -A EXPECTED=(
  [year_round_trip]="2017"
  [month_round_trip]="03"
  [day_round_trip]="25"
  [year_month_round_trip]="2017-03"
  [month_day_round_trip]="03/25"
  [ymd_format_iso]="2016-12-11"
  [sys_days_round_trip]="2021-07-04"
  [weekday_parse]="3"
)

for key in "${!EXPECTED[@]}"; do
  want="${EXPECTED[$key]}"
  # The checker prints "key=value" lines; extract the value.
  got="$(printf '%s\n' "$checker_out" | grep -m1 "^${key}=" | cut -d= -f2-)"
  if [ "$got" = "$want" ]; then
    PASSED=$((PASSED+1))
  else
    echo "FAIL behavioral[$key]: got='$got' want='$want'" >&2
    FAILED=$((FAILED+1))
  fi
done

# Also count the overall checker exit code as one test (catches crashes/sanitizer deaths).
if [ "$checker_rc" -eq 0 ]; then
  PASSED=$((PASSED+1))
else
  echo "FAIL: date_behavior_checker exited $checker_rc" >&2
  FAILED=$((FAILED+1))
fi

# ── 2) tz-free assert-based unit tests (additive coverage) ──────────────────────────────────
if [ -d "$BUILDDIR" ]; then
  shopt -s nullglob
  for bin in "$BUILDDIR"/*; do
    case "$bin" in *.log) continue;; esac
    [ -f "$bin" ] && [ -x "$bin" ] || continue
    name="$(basename "$bin")"
    if "$bin" >/dev/null 2>&1; then
      PASSED=$((PASSED+1))
    else
      rc=$?
      FAILED=$((FAILED+1))
      echo "FAIL ($rc): $name" >&2
    fi
  done
fi

echo "=== date oracle: $PASSED passed, $FAILED failed ==="
emit_ctrf "date-oracle" "$PASSED" "$FAILED" 0
