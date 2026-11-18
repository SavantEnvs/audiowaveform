#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 1) The project's own sources, built with the sanitizers, DWARF 3 and SanCov (fuzzer-no-link) so the fuzzed code
#    is instrumented, not just the harness. Objects go to mayhem/build/ (covered by upstream's `build` ignore).
FUZZ_DIR="$SRC/mayhem/build/fuzz"
mkdir -p "$FUZZ_DIR"

read -r VERSION_MAJOR VERSION_MINOR VERSION_PATCH < <(tr . ' ' < VERSION)
sed -e "s/@VERSION_MAJOR@/$VERSION_MAJOR/" -e "s/@VERSION_MINOR@/$VERSION_MINOR/" \
    -e "s/@VERSION_PATCH@/$VERSION_PATCH/" src/Config.h.in > "$FUZZ_DIR/Config.h"

FUZZ_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS -O1"
export FUZZ_FLAGS FUZZ_DIR

MODULE_SRCS=$(sed -n '/^set(MODULES/,/^)/p' CMakeLists.txt | grep -oE 'src/[^[:space:])]+')
CXX_SRCS=$(echo "$MODULE_SRCS" | grep -E '\.cpp$')
C_SRCS=$(echo "$MODULE_SRCS" | grep -E '\.c$')
export CXX_SRCS C_SRCS

obj_of() { echo "$FUZZ_DIR/$(echo "${1%.*}" | tr / _).o"; }
export -f obj_of

{ for f in $CXX_SRCS; do echo "cxx $f"; done; for f in $C_SRCS; do echo "cc $f"; done; } |
    xargs -P "$MAYHEM_JOBS" -L1 bash -c '
        set -e
        if [ "$0" = cxx ]; then
            $CXX -std=c++11 -DBOOST_FILESYSTEM_NO_DEPRECATED $FUZZ_FLAGS -I"$FUZZ_DIR" -Isrc -c "$1" -o "$(obj_of "$1")"
        else
            $CC -std=c99 $FUZZ_FLAGS -I"$FUZZ_DIR" -Isrc -c "$1" -o "$(obj_of "$1")"
        fi'

PROJECT_OBJS=""
for f in $CXX_SRCS $C_SRCS; do PROJECT_OBJS="$PROJECT_OBJS $(obj_of "$f")"; done

LIBS="-lsndfile -lgd -lmad -lid3tag -lboost_program_options -lboost_filesystem -lboost_regex -lboost_system"

# 2) Each harness twice: libFuzzer binary, and a run-once -standalone reproducer. LeakSanitizer is switched off at
#    build time with lsan_off.cc (ASan and UBSan stay on).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FUZZ_DIR/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$FUZZ_DIR/standalone_main.o"

for t in fuzz_mp3:MODE_MP3 fuzz_audio:MODE_AUDIO fuzz_dat:MODE_DAT fuzz_json:MODE_JSON; do
    name=${t%%:*}; mode=${t##*:}
    $CXX -std=c++11 -DBOOST_FILESYSTEM_NO_DEPRECATED -DHARNESS_MODE=$mode $FUZZ_FLAGS -I"$FUZZ_DIR" -Isrc \
        -c "$SRC/mayhem/harness.cpp" -o "$FUZZ_DIR/$name.o"
    $CXX $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
        "$FUZZ_DIR/$name.o" $PROJECT_OBJS "$FUZZ_DIR/lsan_off.o" $LIBS -o "$SRC/$name"
    $CXX $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS \
        "$FUZZ_DIR/$name.o" $PROJECT_OBJS "$FUZZ_DIR/lsan_off.o" "$FUZZ_DIR/standalone_main.o" $LIBS -o "$SRC/$name-standalone"
done

# 3) The upstream unit tests and the CLI, with the project's NORMAL flags in ./build (upstream's own build dir,
#    ignored by its .gitignore; the tests open ../test/data from there). Upstream expects googletest unpacked at
#    ./googletest (also gitignored), so it is copied from the copy cached in the image.
[ -e googletest ] || cp -r /opt/toolchains/deps/googletest-1.12.1/src googletest
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS"
cmake --build build -j"$MAYHEM_JOBS" --target audiowaveform audiowaveform_tests
