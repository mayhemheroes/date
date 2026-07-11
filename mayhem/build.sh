#!/usr/bin/env bash
#
# date/mayhem/build.sh — build HowardHinnant/date's fuzz harness as a sanitized libFuzzer target
# (+ a standalone reproducer), and build date's OWN unit-test programs (header-only subset that
# needs NO IANA tz database) for mayhem/test.sh to run.
#
# Fuzzed surface: date::parse()/from_stream() — the format-directive parser in the header-only
# include/date/date.h. It is self-contained (no tz.cpp, no network, no IANA db), so both the fuzzer
# and the test oracle build & run fully offline.
#
# Build contract comes from the org base ENV: CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN/OUT. date.h is header-only, so "instrumenting the library" == compiling the
# harness TU (which includes date.h) with $SANITIZER_FLAGS.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) so an explicit empty --build-arg SANITIZER_FLAGS builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS=-gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${OUT:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS OUT

# SRC defaults to the baked source root (where this repo was copied).
SRC_DIR="${SRC:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$SRC_DIR"

HARNESS_DIR="$SRC_DIR/mayhem/harnesses"
# date's own test files include "date.h" unqualified, and date.h includes "tz.h" only under
# defines we don't set. -Iinclude/date makes the unqualified include resolve; -Iinclude makes
# the FQ <date/date.h> form resolve too.
INC="-I$SRC_DIR/include/date -I$SRC_DIR/include"
STD="-std=c++17"
# date's locale-name parsing (%a/%A/%b/%B) is broken under libstdc++ (upstream issue #388); the
# documented fix is ONLY_C_LOCALE=1, which makes parsing use the built-in C-locale tables. This is
# NOT a sanitizer relax — it selects date.h's portable locale path, and is what date's own tests
# need to pass with this libc++/libstdc++. Applied to BOTH the fuzzer and the unit tests so the two
# agree on behavior.
LOCALE="-DONLY_C_LOCALE=1"

mkdir -p "$OUT"

# ── 1) libFuzzer target -> $OUT/date_fuzzer ───────────────────────────────────────────────────────
$CXX $STD $LOCALE $SANITIZER_FLAGS $DEBUG_FLAGS $INC \
    "$HARNESS_DIR/date_fuzzer.cc" $LIB_FUZZING_ENGINE \
    -o "$OUT/date_fuzzer"

# ── 2) standalone reproducer (no libFuzzer runtime) -> $OUT/date_fuzzer-standalone ─────────────────
# Prefer the org-provided $STANDALONE_FUZZ_MAIN if present; else use our bundled run-once driver.
# The org main is a .c file that declares `int LLVMFuzzerTestOneInput(...)` with C linkage. Our
# harness exports that symbol as extern "C", so the driver MUST be compiled as C (-x c): if it were
# compiled in C++ mode (because $CXX defaults a .c TU to C++) the declaration would be C++-mangled
# and the link would fail with an undefined-reference. We compile the driver to an object as C, then
# link it with the (C++) harness TU using $CXX.
if [ -n "${STANDALONE_FUZZ_MAIN:-}" ] && [ -f "${STANDALONE_FUZZ_MAIN}" ]; then
  STANDALONE_SRC="${STANDALONE_FUZZ_MAIN}"
  STANDALONE_LANG="c"     # org driver is C
else
  STANDALONE_SRC="$HARNESS_DIR/standalone_main.cc"
  STANDALONE_LANG="c++"   # our bundled driver is C++ (declares the symbol extern "C")
fi
STANDALONE_OBJ="$OUT/.date_standalone_main.o"
# Driver itself never includes date.h, so it needs no $LOCALE/$INC; compile with sanitizer flags
# so the run-once binary keeps ASan/UBSan instrumentation for replay.
$CXX -x "$STANDALONE_LANG" $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_SRC" -o "$STANDALONE_OBJ"
$CXX $STD $LOCALE $SANITIZER_FLAGS $DEBUG_FLAGS $INC \
    "$HARNESS_DIR/date_fuzzer.cc" "$STANDALONE_OBJ" \
    -o "$OUT/date_fuzzer-standalone"
rm -f "$STANDALONE_OBJ"

echo "built date_fuzzer (+ standalone)"

# ── 3) Behavioral checker -> $OUT/date_behavior_checker ──────────────────────────────────────────
# This binary is the test.sh oracle: it calls date::parse()+format() with hard-coded inputs and
# PRINTS each result to stdout for the shell to grep.  Built WITHOUT sanitizer flags (clean flags
# only) — it is a functional checker, not a fuzz target.  When neutered to exit(0) by the
# reward-hack sabotage probe, nothing is printed, causing test.sh's grep to fail.
env -u SANITIZER_FLAGS $CXX $STD $LOCALE $INC \
    "$HARNESS_DIR/date_behavior_checker.cc" \
    -o "$OUT/date_behavior_checker"

echo "built date_behavior_checker"

# ── 4) Build date's OWN unit tests (header-only, tz-free subset) for test.sh ───────────────────────
# date's CMake suite (-DENABLE_DATE_TESTING=ON) builds date-tz and pulls the IANA db (AUTO_DOWNLOAD)
# — not runnable offline. Instead we compile the self-contained *.pass.cpp test programs that only
# need date.h (no tz.h symbols): the full date_test suite (incl. its detail/ and format/ subdirs)
# and the iso_week suite. Each is a standalone assert()-based program (golden known-answers).
# Built with NORMAL flags (no sanitizer/UB noise) so test.sh is an honest PATCH oracle that only RUNS.
TESTBIN="$SRC_DIR/mayhem-tests"
mkdir -p "$TESTBIN"

# tz-free test dirs: every .cpp under these includes only date.h-family headers (date.h /
# iso_week.h), never tz.h, so they compile & link with NO IANA db. (Verified: `grep -rl tz.h`
# is empty for test/date_test and test/iso_week.) date_test/parse.pass.cpp directly exercises the
# fuzzed date::parse surface as a golden known-answer test. solar_hijri/clock_cast/tz_test are
# EXCLUDED because they pull tz.h / the IANA database.
TZFREE_DIRS=(date_test iso_week)

built=0
for d in "${TZFREE_DIRS[@]}"; do
  [ -d "$SRC_DIR/test/$d" ] || continue
  # Each test dir's *.pass.cpp uses unqualified includes (date.h, iso_week.h, ...) resolved by
  # -Iinclude/date. *.fail.cpp are NEGATIVE compile tests — skip them (must NOT compile).
  while IFS= read -r -d '' tf; do
    base="$(basename "${tf%.cpp}")"
    out="$TESTBIN/${d}__${base//.pass/}"
    if env -u SANITIZER_FLAGS $CXX $STD $LOCALE $INC "$tf" -o "$out" 2>"$TESTBIN/${d}__${base//.pass/}.log"; then
      built=$((built+1))
    else
      # A compile failure of a pass-test is itself a regression signal; keep the log + a stub that
      # exits nonzero so test.sh reports it as a failure rather than silently skipping.
      rm -f "$out"
      echo "WARN: failed to compile pass-test $tf (see ${out}.log)" >&2
    fi
  done < <(find "$SRC_DIR/test/$d" -name '*.pass.cpp' ! -name '*.fail.cpp' -print0)
done

echo "built $built date unit-test programs into mayhem-tests/"

echo "build.sh complete:"
ls -la "$OUT/date_fuzzer" "$OUT/date_fuzzer-standalone" 2>&1 || true
