#!/usr/bin/env bash
#
# mayhem/test.sh — RUN FreeImage's own upstream test suite (TestAPI/), prebuilt by mayhem/build.sh
# as /mayhem/testAPI with the project's normal flags (asserts live, no NDEBUG). Never compiles.
#
# TestAPI is the ENTIRE upstream suite: one binary whose main() runs 13 assert-based functional test
# groups (plugins, clone, image types, TIFF round-trips, memory IO, multipage build/clone/lock/cache,
# multipage streams, JPEG lossless transforms, channels, header-only, Exif raw, wrapped buffers,
# views); testThumbnail is disabled UPSTREAM (commented out "// FIXME" in MainTestSuite.cpp), so it
# is reported as skipped. Any assert failure aborts the binary.
#
# Behavioral (not reward-hackable): beyond exit-0 we assert the run's OUTPUT — every per-group banner
# the suite prints must appear, and the multipage tests must have actually produced their output
# artifacts (sample.tif, clone.tif, mpages.tif). A neutered exit(0) binary prints nothing and
# produces no artifacts, so it fails.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:-/mayhem}"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}"
  local tests=$(( passed + failed + skipped ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": { "tests": $tests, "passed": $passed, "failed": $failed, "pending": 0, "skipped": $skipped, "other": 0 }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":0,"skipped":%d,"other":0}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$skipped"
  [ "$failed" -eq 0 ]
}

if [ ! -x /mayhem/testAPI ]; then
  echo "test.sh: /mayhem/testAPI missing — mayhem/build.sh must build it (not rebuilding here)" >&2
  emit_ctrf freeimage-testapi 0 13 1; exit 1
fi

# The suite reads its sample images from CWD and writes outputs there; the image dir may be
# read-only at replay time, so run in a scratch copy under /tmp.
WORK=$(mktemp -d /tmp/testapi.XXXXXX)
cp TestAPI/exif.jpg TestAPI/exif.jxr TestAPI/sample.png "$WORK"/
cd "$WORK"

out="$(/mayhem/testAPI 2>&1)"; rc=$?
echo "$out"

# The 13 upstream test groups, in main() order, each with its behavioral evidence:
#   name : required stdout marker (all groups print a banner) [+ artifact]
declare -a groups=(
  "showPlugins:FreeImage version"
  "testAllocateCloneUnload:testAllocateCloneUnload ..."
  "testImageType:testImageType ..."
  "testImageTypeTIFF:testImageTypeTIFF ..."
  "testMemIO:testMemIO ..."
  "testMultiPage:testMultiPage ..."
  "testStreamMultiPage:testStreamMultiPage ..."
  "testMultiPageMemory:testMultiPageMemory ..."
  "testJPEG:testJPEG"
  "testImageChannels:testImageChannels ..."
  "testHeaderOnly:testHeaderOnly ..."
  "testExifRaw:testExifRaw ..."
  "testWrappedBuffer:"   # prints no banner — evidence is rc==0 (an assert abort is fatal)
  "testCreateView:"      # prints no banner — evidence is rc==0
)

passed=0; failed=0
for g in "${groups[@]}"; do
  name="${g%%:*}"; marker="${g#*:}"
  if [ "$rc" -eq 0 ] && grep -qF "$marker" <<<"$out"; then
    echo "  ok   - $name"; passed=$((passed+1))
  else
    echo "  FAIL - $name"; failed=$((failed+1))
  fi
done

# Artifact assertions: the multipage groups must have really written their outputs.
for f in sample.tif clone.tif mpages.tif clone-stream.tif; do
  if [ -s "$f" ]; then echo "  ok   - artifact $f"; passed=$((passed+1))
  else echo "  FAIL - artifact $f"; failed=$((failed+1)); fi
done

cd "${SRC:-/mayhem}"; rm -rf "$WORK"
echo "test.sh: passed=$passed failed=$failed (skipped=1: testThumbnail disabled upstream)"
emit_ctrf freeimage-testapi "$passed" "$failed" 1
