#!/bin/bash
# Compare loggen avg_rate before vs after the devirtualization changes.
# Waits for syslog-ng to print "starting up" before launching loggen,
# ensuring JIT compilation is done before measurement starts.

REPO=/home/bferencz/Development/axosyslog-jit
BUILD=$REPO/build
SNG=$BUILD/syslog-ng/syslog-ng
LOGGEN=$BUILD/tests/loggen/loggen
PERF_CONF=/home/bferencz/Development/fernya-jit-tests/perf.conf
export SYSLOG_NG_FILTERX_JIT_LLVM_ARGS="${SYSLOG_NG_FILTERX_JIT_LLVM_ARGS:-}"

run_once() {
  local label="$1"
  echo "--- $label ---"

  pkill -9 -f "$SNG" 2>/dev/null; sleep 2

  # Start syslog-ng, capture its output to a temp file
  TMPLOG=$(mktemp)
  "$SNG" -Fe -f "$PERF_CONF" >"$TMPLOG" 2>&1 &
  SNG_PID=$!

  # Wait until syslog-ng prints "starting up" (JIT done) or timeout 120s
  for i in $(seq 1 120); do
    sleep 1
    if grep -q "starting up" "$TMPLOG" 2>/dev/null; then
      echo "  syslog-ng ready after ${i}s"
      break
    fi
    if ! kill -0 $SNG_PID 2>/dev/null; then
      echo "  syslog-ng DIED; last output:"
      tail -3 "$TMPLOG"
      rm -f "$TMPLOG"
      return 1
    fi
  done

  # Run loggen
  RESULT=$("$LOGGEN" -iS --perf --active-connections 4 --interval 30 127.0.0.1 2000 2>&1 | tail -1)
  echo "  $RESULT"
  AVG=$(echo "$RESULT" | grep -oP 'avg_rate=\K[0-9.]+')
  echo "  avg_rate = $AVG msg/s"

  kill $SNG_PID 2>/dev/null
  wait $SNG_PID 2>/dev/null
  rm -f "$TMPLOG"
  sleep 2
  echo ""
}

echo "=== Performance comparison: devirtualize-plus branch ==="
echo "SYSLOG_NG_FILTERX_JIT_LLVM_ARGS: ${SYSLOG_NG_FILTERX_JIT_LLVM_ARGS:-(none)}"
echo ""

make -C "$BUILD" -j$(nproc) syslog-ng >/dev/null 2>&1

# Run 2 passes with current (patched) build
echo ">>> PATCHED (with INTEGER/per-key/cross-block devirtualization)"
run_once "patched run 1"
run_once "patched run 2"

# Run 2 passes with current (patched) build, no aggressive inlining
echo ">>> PATCHED without aggressive inlining (with INTEGER/per-key/cross-block devirtualization)"
export SYSLOG_NG_NO_AGGRESSIVE_INLINE=1
run_once "patched run 3"
run_once "patched run 4"
unset SYSLOG_NG_NO_AGGRESSIVE_INLINE

# Stash changes and rebuild for baseline
echo ">>> BASELINE (HEAD without devirt-plus changes)"
git -C "$REPO" stash push --quiet -m "perf-compare-stash"
make -C "$BUILD" -j$(nproc) syslog-ng >/dev/null 2>&1
run_once "baseline run 1"
run_once "baseline run 2"

echo ">>> BASELINE without aggressive inlining"
export SYSLOG_NG_NO_AGGRESSIVE_INLINE=1
run_once "baseline run 3"
run_once "baseline run 4"
unset SYSLOG_NG_NO_AGGRESSIVE_INLINE

git -C "$REPO" stash pop --quiet
make -C "$BUILD" -j$(nproc) syslog-ng >/dev/null 2>&1
echo "(patched restored)"
