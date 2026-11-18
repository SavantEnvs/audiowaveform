#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
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

# Runs the pre-built upstream gtest suite from build/ (the tests open ../test/data), plus direct known-answer
# probes of the audiowaveform CLI against upstream's golden files. Two groups are skipped: ProgressReporterTest
# (as in upstream's own CI; timing/terminal dependent) and the Opus golden-file tests, whose expected samples
# are off by one under the libopus the image ships.
BUILD="$SRC/build"
for b in "$BUILD/audiowaveform_tests" "$BUILD/audiowaveform"; do
  [ -x "$b" ] || { echo "missing $b: mayhem/build.sh should have built it" >&2; emit_ctrf "audiowaveform" 0 1 0; exit 1; }
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/aw-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

passed=0; failed=0
DATA="$SRC/test/data"

probe() {  # probe <name> <golden> <audiowaveform args...>: output file is $TMP/out
  local name="$1" golden="$2"; shift 2
  rm -f "$TMP/out"
  if "$BUILD/audiowaveform" -q "$@" -o "$TMP/out" >/dev/null 2>&1 && cmp -s "$TMP/out" "$golden"; then
    passed=$((passed + 1)); echo "PASS probe $name"
  else
    failed=$((failed + 1)); echo "FAIL probe $name"
  fi
}

probe wav-to-dat "$DATA/test_file_mono_float32_8bit_64spp.dat" \
  -i "$DATA/test_file_mono_float32.wav" --input-format wav --output-format dat -z 64 -b 8
probe dat-to-txt "$DATA/07023003_8bit_64spp_2channel.txt" \
  -i "$DATA/07023003_8bit_64spp_2channel.dat" --input-format dat --output-format txt
probe dat-to-json "$DATA/07023003_8bit_64spp_2channel.json" \
  -i "$DATA/07023003_8bit_64spp_2channel.dat" --input-format dat --output-format json

# mp3 decode: the dat/json from the stereo mp3 must match upstream's golden output
probe mp3-to-dat "$DATA/test_file_stereo_8bit_64spp_mp3.dat" \
  -i "$DATA/test_file_stereo.mp3" --input-format mp3 --output-format dat -z 64 -b 8

# the CLI must reject bad input with a non-zero status
if "$BUILD/audiowaveform" -q -i "$DATA/not_enough_channels.dat" --input-format dat -o "$TMP/bad.json" --output-format json >/dev/null 2>&1; then
  failed=$((failed + 1)); echo "FAIL probe reject-zero-channels"
else
  [ -e "$TMP/bad.json" ] && { failed=$((failed + 1)); echo "FAIL probe reject-zero-channels (wrote output)"; } \
    || { passed=$((passed + 1)); echo "PASS probe reject-zero-channels"; }
fi

cd "$BUILD"
out=$("$BUILD/audiowaveform_tests" --gtest_filter='-ProgressReporterTest.*:*Opus*' 2>&1)
rc=$?
printf '%s\n' "$out" | tail -n 40
gp=$(printf '%s\n' "$out" | sed -n 's/^\[  PASSED  \] \([0-9]*\) test.*/\1/p' | tail -n1)
gf=$(printf '%s\n' "$out" | sed -n 's/^\[  FAILED  \] \([0-9]*\) test.*/\1/p' | tail -n1)
gs=$(printf '%s\n' "$out" | sed -n 's/^\[  SKIPPED \] \([0-9]*\) test.*/\1/p' | tail -n1)
gp=${gp:-0}; gf=${gf:-0}; gs=${gs:-0}
if [ "$gp" -eq 0 ] || [ "$rc" -ne 0 -a "$gf" -eq 0 ]; then gf=$((gf + 1)); fi  # no summary / crashed: a failure

emit_ctrf "audiowaveform" $((passed + gp)) $((failed + gf)) "$gs"
