#!/bin/bash
# Compare loggen avg_rate before vs after the devirtualization changes.
# Waits for syslog-ng to print "starting up" before launching loggen,
# ensuring JIT compilation is done before measurement starts.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=/home/bferencz/Development/axosyslog-jit
BUILD=$REPO/build
SNG_LOCAL=$BUILD/syslog-ng/.libs/syslog-ng
export SYSLOG_NG_FILTERX_JIT_LLVM_ARGS="${SYSLOG_NG_FILTERX_JIT_LLVM_ARGS:-}"

SNG_HOST=axoflow@10.192.26.26
SNG_KEY=/home/bferencz/Development/fernya-jit-tests/id_rsa.axorouter
REMOTE_SNG=/home/axoflow/jit-tests/syslog-ng
LOGGEN_HOST=axoflow@10.192.25.208
LOGGEN_KEY=/home/bferencz/Development/fernya-jit-tests/id_rsa.loggen
LOCAL_PERF_CONF=/home/bferencz/Development/fernya-jit-tests/perf.conf
REMOTE_PERF_CONF=/home/axoflow/jit-tests/perf_split.conf
BASELINE_COMMIT=56265ebd44215a370bbcb5f3602885c91c6fab42

usage() {
  cat >&2 <<EOF
Usage: $0 OPTIONS
  --sng-host    HOST   SSH host (user@ip) for syslog-ng
  --sng-key     FILE   SSH private key for syslog-ng host
  --sng-path    PATH   Remote path to deploy syslog-ng launcher (default: $REMOTE_SNG)
  --loggen-host HOST   SSH host (user@ip) for loggen
  --loggen-key  FILE   SSH private key for loggen host
  --sng-conf    PATH   Remote path for syslog-ng config (default: $REMOTE_PERF_CONF)
  --local-conf  PATH   Local syslog-ng config to deploy (default: $LOCAL_PERF_CONF)
  --baseline    SHA    Baseline commit to compare against (default: $BASELINE_COMMIT)
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sng-host)    SNG_HOST="$2";         shift 2 ;;
    --sng-key)     SNG_KEY="$2";          shift 2 ;;
    --sng-path)    REMOTE_SNG="$2";       shift 2 ;;
    --loggen-host) LOGGEN_HOST="$2";      shift 2 ;;
    --loggen-key)  LOGGEN_KEY="$2";       shift 2 ;;
    --sng-conf)    REMOTE_PERF_CONF="$2"; shift 2 ;;
    --local-conf)  LOCAL_PERF_CONF="$2";  shift 2 ;;
    --baseline)    BASELINE_COMMIT="$2";  shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$SNG_HOST" && -n "$SNG_KEY" && -n "$REMOTE_SNG" && \
   -n "$LOGGEN_HOST" && -n "$LOGGEN_KEY" ]] || usage

SSH_OPTS=(-o StrictHostKeyChecking=no -o BatchMode=yes)

sng_ssh()    { ssh "${SSH_OPTS[@]}" -i "$SNG_KEY"    "$SNG_HOST"    "$@"; }
loggen_ssh() { ssh "${SSH_OPTS[@]}" -i "$LOGGEN_KEY" "$LOGGEN_HOST" "$@"; }
scp_to_sng() { scp "${SSH_OPTS[@]}" -i "$SNG_KEY"    "$1" "$SNG_HOST:$2"; }

# The loader script (scripts/jit/syslog-ng) expects SYSLOG_NG_PREFIX to point
# to a directory with the syslog-ng/.libs/ and lib/.libs/ tree.  We place that
# tree in a "build" subdirectory next to the deployed launcher so the launcher
# path itself stays a plain file.
remote_prefix() { echo "$(dirname "$REMOTE_SNG")/build"; }

deploy() {
  local rprefix
  rprefix=$(remote_prefix)

  echo "Deploying syslog-ng config to $SNG_HOST:$REMOTE_PERF_CONF ..."
  sng_ssh "mkdir -p '$(dirname "$REMOTE_PERF_CONF")'"
  scp_to_sng "$LOCAL_PERF_CONF" "$REMOTE_PERF_CONF"

  echo "Deploying syslog-ng to $SNG_HOST ..."
  sng_ssh "mkdir -p '$rprefix/syslog-ng/.libs' '$rprefix/lib/.libs' '$rprefix/lib/secret-storage/.libs' '$rprefix/modules'"
  scp_to_sng "$SCRIPT_DIR/syslog-ng"  "$REMOTE_SNG"
  sng_ssh "chmod +x '$REMOTE_SNG'"
  scp_to_sng "$SNG_LOCAL"             "$rprefix/syslog-ng/.libs/syslog-ng"
  echo "Deploying syslog-ng modules to $SNG_HOST:$rprefix/modules ..."
  find "$BUILD/modules" -name '*.so' -print0 | \
    tar -czf - --null -T - --transform='s|.*/||' | \
    ssh "${SSH_OPTS[@]}" -i "$SNG_KEY" "$SNG_HOST" \
      "cd '$rprefix/modules' && tar -xzf -"
}

# run_once LABEL [EXTRA_ENV]
# EXTRA_ENV is a space-separated list of VAR=value assignments injected into
# the remote syslog-ng process (e.g. "SYSLOG_NG_AGGRESSIVE_INLINE=1").  The
# local SYSLOG_NG_FILTERX_JIT_CODEGEN and SYSLOG_NG_FILTERX_JIT_LLVM_ARGS
# values are always relayed, so exporting them before invoking this script
# applies them to every run.
run_once() {
  local label="$1"
  local extra_env="${2:-}"
  local rprefix
  rprefix=$(remote_prefix)
  echo "--- $label ---"

  sng_ssh "pkill -9 -x syslog-ng 2>/dev/null; sleep 2" || true

  local remote_tmplog
  remote_tmplog=$(sng_ssh "mktemp")

  # Start syslog-ng on the remote host in the background; capture its PID
  local sng_pid
  sng_pid=$(sng_ssh "nohup env SYSLOG_NG_PREFIX='$rprefix' SYSLOG_NG_FILTERX_JIT_CODEGEN='${SYSLOG_NG_FILTERX_JIT_CODEGEN}' SYSLOG_NG_FILTERX_JIT_LLVM_ARGS='${SYSLOG_NG_FILTERX_JIT_LLVM_ARGS}' ${extra_env:+$extra_env }'$REMOTE_SNG' --module-path '$rprefix/modules' -R '$rprefix/syslog-ng.persist' --pidfile '$rprefix/syslog-ng.pid' -c '$rprefix/syslog-ng.ctl' -Fe -f '$REMOTE_PERF_CONF' >'$remote_tmplog' 2>&1 & echo \$!")

  # Wait until syslog-ng prints "starting up" (JIT done) or timeout 120s
  local ready=0
  for i in $(seq 1 120); do
    sleep 1
    if sng_ssh "grep -q 'starting up' '$remote_tmplog'" 2>/dev/null; then
      echo "  syslog-ng ready after ${i}s"
      ready=1
      break
    fi
    if ! sng_ssh "kill -0 $sng_pid" 2>/dev/null; then
      echo "  syslog-ng DIED; last output:"
      sng_ssh "tail -20 '$remote_tmplog'"
      sng_ssh "rm -f '$remote_tmplog'"
      return 1
    fi
  done

  if [[ $ready -eq 0 ]]; then
    echo "  syslog-ng did not start within 120s"
    sng_ssh "kill $sng_pid 2>/dev/null; rm -f '$remote_tmplog'"
    return 1
  fi

  # Run loggen via container on the loggen host, connecting to the syslog-ng host
  RESULT=$(loggen_ssh "sudo podman run --init --network=host --entrypoint loggen --rm -it ghcr.io/axoflow/axosyslog -iS --perf --active-connections 4 --interval 30 ${SNG_HOST##*@} 2000 2>&1 | tail -1")
  echo "  $RESULT"
  AVG=$(echo "$RESULT" | grep -oP 'avg_rate=\K[0-9.]+')
  echo "  avg_rate = $AVG msg/s"

  sng_ssh "kill $sng_pid 2>/dev/null; rm -f '$remote_tmplog'"
  sleep 2
  echo ""
}

echo "=== Performance comparison: devirtualize-plus branch ==="
echo "SYSLOG_NG_FILTERX_JIT_LLVM_ARGS: ${SYSLOG_NG_FILTERX_JIT_LLVM_ARGS:-(none)}"
echo ""

make -C "$BUILD" -j$(nproc) syslog-ng >/dev/null 2>&1
deploy

# Run 2 passes with the tip (current branch) build
echo ">>> TIP ($(git -C "$REPO" rev-parse --short HEAD))"
run_once "tip run 1"
run_once "tip run 2"

# Checkout baseline commit and rebuild
CURRENT_BRANCH=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
echo ">>> BASELINE (${BASELINE_COMMIT:0:9})"
git -C "$REPO" stash push --quiet -m "perf-compare-stash"
git -C "$REPO" checkout --detach "$BASELINE_COMMIT"
make -C "$BUILD" -j$(nproc) syslog-ng >/dev/null 2>&1
deploy
run_once "baseline run 1"
run_once "baseline run 2"

git -C "$REPO" checkout "$CURRENT_BRANCH"
git -C "$REPO" stash pop --quiet
make -C "$BUILD" -j$(nproc) syslog-ng >/dev/null 2>&1
deploy
echo "(patched restored)"
