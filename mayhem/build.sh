#!/usr/bin/env bash
#
# mayhem/build.sh — build FreeImage twice (normal oracle build + sanitized fuzz build)
# and the load_from_memory_fuzzer harness (fuzzer + standalone reproducer).
#
#   /mayhem/testAPI                           upstream TestAPI suite, NORMAL flags (oracle; test.sh runs it)
#   /mayhem/load_from_memory_fuzzer           libFuzzer harness, ASan+UBSan-instrumented library
#   /mayhem/load_from_memory_fuzzer-standalone run-once reproducer (same harness, $STANDALONE_FUZZ_MAIN)
#
# FreeImage builds with Makefile.gnu (vendored zlib/libpng/libjpeg/libtiff/openjpeg/openexr/
# libraw/libwebp/libjxr all compiled from Source/ — no network). Two upstream quirks:
#   * Source/OpenEXR/IlmImf/b44ExpLogTable.cpp defines main() — the historical OSS-Fuzz build
#     drops it from SRCS (it is a table GENERATOR, not library code); we pass a filtered SRCS
#     on the make command line instead of editing Makefile.srcs (keeps the tree pristine).
#   * OpenEXR needs -std=c++14 under modern clang.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "${SRC:-/mayhem}"

# Makefile.gnu uses `CFLAGS ?=` / `CXXFLAGS ?=`, so we supply the full base flags + our extras.
BASE_C="-O2 -fPIC -fexceptions -fvisibility=hidden -w"
BASE_CXX="-O2 -fPIC -fexceptions -fvisibility=hidden -Wno-ctor-dtor-privacy -std=c++14 -w"

# SRCS with the main()-bearing OpenEXR table generator removed (see header comment), plus
# Source/LibTIFF4/tif_hash_set.c which upstream's Makefile.srcs forgot when libtiff was bumped
# to 4.5 (CMakeLists.txt has it; without it libfreeimage.a has undefined TIFFHashSet* refs).
FILTERED_SRCS="$(sed -n 's/^SRCS = //p' Makefile.srcs | sed 's|\./Source/OpenEXR/IlmImf/b44ExpLogTable\.cpp||') Source/LibTIFF4/tif_hash_set.c"

build_lib() {  # build_lib <cflags-extra> <cxxflags-extra>
  make -f Makefile.gnu clean >/dev/null 2>&1 || true
  # CFLAGS/CXXFLAGS go through the ENVIRONMENT (not make's command line) so Makefile.gnu's
  # `+=` lines (-DOPJ_STATIC, -DNO_LCMS, -D__ANSI__, $(INCLUDE)…) still append. SRCS must be a
  # command-line override (it is `=`-assigned in Makefile.srcs).
  env CC="$CC" CXX="$CXX" \
      CFLAGS="-std=gnu89 $BASE_C $1" \
      CXXFLAGS="$BASE_CXX $2" \
    make -f Makefile.gnu -j"$MAYHEM_JOBS" SRCS="$FILTERED_SRCS" libfreeimage.a
  mkdir -p Dist
  cp libfreeimage.a Dist/
  cp Source/FreeImage.h Dist/
}

# ---- 1) NORMAL (oracle) build: library + upstream TestAPI suite ---------------------------------
if [ ! -x /mayhem/testAPI ]; then
  build_lib "$COVERAGE_FLAGS" "$COVERAGE_FLAGS"
  # TestAPI/Makefile: g++ -I../Dist *.cpp ../Dist/libfreeimage.a -o testAPI  (asserts stay live)
  $CXX -O1 -std=c++14 -w $COVERAGE_FLAGS -I Dist TestAPI/*.cpp Dist/libfreeimage.a -o /mayhem/testAPI -lstdc++ -lm -lpthread
fi

# ---- 2) SANITIZED fuzz build: library + harness (fuzzer + standalone) ---------------------------
build_lib "$SANITIZER_FLAGS $DEBUG_FLAGS" "$SANITIZER_FLAGS $DEBUG_FLAGS"

# shellcheck disable=SC2086
$CXX -std=c++14 -w $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE -I Dist \
  mayhem/load_from_memory_fuzzer.cc Dist/libfreeimage.a \
  -o /mayhem/load_from_memory_fuzzer -lstdc++ -lm -lpthread

# Standalone run-once reproducer: compile the C driver with $CC so LLVMFuzzerTestOneInput keeps C linkage.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
# shellcheck disable=SC2086
$CXX -std=c++14 -w $SANITIZER_FLAGS $DEBUG_FLAGS -I Dist \
  mayhem/load_from_memory_fuzzer.cc /tmp/standalone_main.o Dist/libfreeimage.a \
  -o /mayhem/load_from_memory_fuzzer-standalone -lstdc++ -lm -lpthread

echo "build.sh: built /mayhem/testAPI, /mayhem/load_from_memory_fuzzer(+standalone)"
