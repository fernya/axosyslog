#!/bin/bash
# Sweep JIT codegen-related env vars and report generated-code size.
#
# Stage 1 ("patch and build") injects IR_SIZE/IR_OPT_SIZE/MC_SIZE printing and
# per-module object dumping into lib/filterx/jit/jit.c, then builds.  If the
# script did the patching, jit.c is restored on exit (the build tree keeps the
# instrumentation until the next make).  An already-instrumented jit.c is left
# untouched.
#
# Stage 2 runs each case and, besides the size totals, dumps the emitted
# object file(s) of every JIT module plus a per-function size listing under
# $OBJ_BASE/<case>/.
#
# Usage: tune_codegen_size.sh [results-file]

REPO=/home/bferencz/Development/axosyslog-jit
BUILD=$REPO/build
SNG=$BUILD/syslog-ng/syslog-ng
JIT_C=$REPO/lib/filterx/jit/jit.c
PERF_CONF=${PERF_CONF:-/home/bferencz/Development/fernya-jit-tests/perf_split.conf}
RESULTS=${1:-/tmp/jit_size_tuning.txt}
OBJ_BASE=${OBJ_BASE:-/tmp/jit_size_objs}

# --- Stage 1: patch and build -----------------------------------------------

inject_instrumentation() {
  python3 - "$JIT_C" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    src = f.read()

if 'OBJ_DUMP' in src:
    print("ALREADY")
    sys.exit(0)
if 'IR_OPT_SIZE' in src:
    # instrumented by an older variant without object dumping
    print("STALE")
    sys.exit(0)

src = src.replace(
    '#include <llvm-c/Support.h>\n',
    '#include <llvm-c/Support.h>\n#include <llvm-c/Object.h>\n',
    1
)

needle = '  LLVMOrcThreadSafeModuleRef ts_mod = LLVMOrcCreateNewThreadSafeModule(self->mod, self->ts_ctx);\n'
patch = (
    '  { unsigned _n = 0;\n'
    '    for (LLVMValueRef _f = LLVMGetFirstFunction(self->mod); _f; _f = LLVMGetNextFunction(_f))\n'
    '      for (LLVMBasicBlockRef _b = LLVMGetFirstBasicBlock(_f); _b; _b = LLVMGetNextBasicBlock(_b))\n'
    '        for (LLVMValueRef _i = LLVMGetFirstInstruction(_b); _i; _i = LLVMGetNextInstruction(_i))\n'
    '          _n++;\n'
    '    fprintf(stderr, "IR_SIZE %u\\n", _n); }\n'
    '  { LLVMModuleRef _mc = LLVMCloneModule(self->mod);\n'
    '    LLVMPassBuilderOptionsRef _o = LLVMCreatePassBuilderOptions();\n'
    '    const gchar *_pp = g_getenv("SYSLOG_NG_FILTERX_JIT_PASSES");\n'
    '    LLVMRunPasses(_mc, (_pp && *_pp) ? _pp : "default<O3>", self->tm, _o);\n'
    '    LLVMDisposePassBuilderOptions(_o);\n'
    '    { unsigned _n2 = 0;\n'
    '      for (LLVMValueRef _f = LLVMGetFirstFunction(_mc); _f; _f = LLVMGetNextFunction(_f))\n'
    '        for (LLVMBasicBlockRef _b = LLVMGetFirstBasicBlock(_f); _b; _b = LLVMGetNextBasicBlock(_b))\n'
    '          for (LLVMValueRef _i = LLVMGetFirstInstruction(_b); _i; _i = LLVMGetNextInstruction(_i))\n'
    '            _n2++;\n'
    '      fprintf(stderr, "IR_OPT_SIZE %u\\n", _n2); }\n'
    '    LLVMMemoryBufferRef _buf = NULL; char *_em = NULL; size_t _mcs = 0;\n'
    '    if (!LLVMTargetMachineEmitToMemoryBuffer(self->tm, _mc, LLVMObjectFile, &_em, &_buf)) {\n'
    '      const gchar *_objdir = g_getenv("SYSLOG_NG_FILTERX_JIT_DUMP_OBJ_DIR");\n'
    '      if (_objdir) {\n'
    '        static unsigned _objidx = 0;\n'
    '        gchar *_fn = g_strdup_printf("%s/fxjit_obj_%u.o", _objdir, _objidx++);\n'
    '        FILE *_fp = fopen(_fn, "wb");\n'
    '        if (_fp) { fwrite(LLVMGetBufferStart(_buf), 1, LLVMGetBufferSize(_buf), _fp); fclose(_fp); }\n'
    '        fprintf(stderr, "OBJ_DUMP %s\\n", _fn);\n'
    '        g_free(_fn); }\n'
    '      LLVMBinaryRef _bin = LLVMCreateBinary(_buf, self->ctx, &_em);\n'
    '      if (_bin) {\n'
    '        LLVMSectionIteratorRef _si = LLVMObjectFileCopySectionIterator(_bin);\n'
    '        while (!LLVMObjectFileIsSectionIteratorAtEnd(_bin, _si)) {\n'
    '          const char *_sn = LLVMGetSectionName(_si);\n'
    '          if (_sn && (strncmp(_sn, ".text", 5) == 0 || strncmp(_sn, ".ltext", 6) == 0 || strncmp(_sn, "__text", 6) == 0))\n'
    '            _mcs += (size_t) LLVMGetSectionSize(_si);\n'
    '          LLVMMoveToNextSection(_si);\n'
    '        }\n'
    '        LLVMDisposeSectionIterator(_si);\n'
    '        LLVMDisposeBinary(_bin);\n'
    '      } else if (_em) { LLVMDisposeMessage(_em); }\n'
    '      LLVMDisposeMemoryBuffer(_buf);\n'
    '    } else if (_em) { LLVMDisposeMessage(_em); }\n'
    '    LLVMDisposeModule(_mc);\n'
    '    fprintf(stderr, "MC_SIZE %zu\\n", _mcs); }\n'
    + needle
)
patched = src.replace(needle, patch, 1)
with open(path, 'w') as f:
    f.write(patched)
print("OK" if patched != src else "FAILED")
PYEOF
}

JIT_C_BACKUP=""

restore_jit_c() {
  if [ -n "$JIT_C_BACKUP" ] && [ -f "$JIT_C_BACKUP" ]; then
    cp "$JIT_C_BACKUP" "$JIT_C"
    rm -f "$JIT_C_BACKUP"
    echo "Restored $JIT_C (build tree still contains instrumentation until next make)"
  fi
}

patch_and_build() {
  local backup
  backup=$(mktemp /tmp/jit_c_backup.XXXXXX)
  cp "$JIT_C" "$backup"

  local status
  status=$(inject_instrumentation)
  case "$status" in
    OK)
      JIT_C_BACKUP="$backup"
      trap restore_jit_c EXIT
      echo "Patched $JIT_C with size/object-dump instrumentation"
      ;;
    ALREADY)
      rm -f "$backup"
      echo "$JIT_C is already instrumented, leaving it as is"
      ;;
    STALE)
      rm -f "$backup"
      echo "ERROR: $JIT_C carries an older instrumentation without object dumping." >&2
      echo "       Restore it first (e.g. git checkout -- lib/filterx/jit/jit.c) and rerun." >&2
      exit 1
      ;;
    *)
      rm -f "$backup"
      echo "ERROR: failed to patch $JIT_C (injection needle not found?)" >&2
      exit 1
      ;;
  esac

  echo -n "Building... "
  local t0=$SECONDS
  if ! make -C "$BUILD" -j"$(nproc)" syslog-ng >/tmp/jit_tune_build.log 2>&1; then
    echo "FAILED"
    grep "error:" /tmp/jit_tune_build.log | head -3
    exit 1
  fi
  echo "done in $((SECONDS-t0))s"
}

# --- Stage 2: measurements ---------------------------------------------------

# One measurement: start syslog-ng, wait for MC_SIZE to appear, kill, tally.
# Dumps per-module objects and a per-function size listing under
# $OBJ_BASE/<case>/.
# $1 label, then env assignments as remaining args (VAR=value ...)
run_one() {
  local label="$1"; shift
  local tmpout objdir
  tmpout=$(mktemp)
  objdir="$OBJ_BASE/$(echo "$label" | tr ' /<>=' '_____')"
  rm -rf "$objdir"
  mkdir -p "$objdir"

  env "$@" SYSLOG_NG_FILTERX_JIT_DUMP_OBJ_DIR="$objdir" \
      timeout 180 "$SNG" -Fe -f "$PERF_CONF" >"$tmpout" 2>&1 &
  local pid=$!

  local ok=0
  for i in $(seq 1 360); do
    if grep -q "^MC_SIZE " "$tmpout" 2>/dev/null; then ok=1; break; fi
    kill -0 $pid 2>/dev/null || break
    sleep 0.5
  done
  kill $pid 2>/dev/null
  wait $pid 2>/dev/null

  local ir irot mc t
  ir=$(awk '/^IR_SIZE /{s+=$2} END{print s+0}' "$tmpout")
  irot=$(awk '/^IR_OPT_SIZE /{s+=$2} END{print s+0}' "$tmpout")
  mc=$(awk '/^MC_SIZE /{s+=$2} END{print s+0}' "$tmpout")
  t=$((i / 2))

  if [ "$ok" = 1 ]; then
    printf "%-58s ir=%-7s ir_opt=%-7s mc=%-8s (~%ss)\n" "$label" "$ir" "$irot" "$mc" "$t" | tee -a "$RESULTS"
    dump_function_sizes "$label" "$objdir"
  else
    printf "%-58s FAILED\n" "$label" | tee -a "$RESULTS"
    echo "--- last output for $label ---" >> "$RESULTS"
    tail -5 "$tmpout" >> "$RESULTS"
    rm -rf "$objdir"
  fi
  rm -f "$tmpout"
}

# Per-function size listing of all dumped objects of a case.
# Written to <objdir>/functions.txt and appended to $RESULTS.
dump_function_sizes() {
  local label="$1" objdir="$2"
  local listing="$objdir/functions.txt"
  local nobjs
  nobjs=$(ls "$objdir"/fxjit_obj_*.o 2>/dev/null | wc -l)
  if [ "$nobjs" -eq 0 ]; then
    echo "  (no objects dumped)" | tee -a "$RESULTS"
    return
  fi

  > "$listing"
  local obj
  for obj in "$objdir"/fxjit_obj_*.o; do
    [ "$nobjs" -gt 1 ] && echo "--- $(basename "$obj") ---" >> "$listing"
    nm --size-sort -t d "$obj" | awk '{printf "  %10d  %s  %s\n", $1, $2, $3}' | tac >> "$listing"
  done

  cat "$listing" >> "$RESULTS"
  echo "  objects + per-function listing: $objdir ($nobjs object(s))"
}

# --- Main --------------------------------------------------------------------

patch_and_build

> "$RESULTS"
echo "=== JIT codegen size sweep ($(basename "$PERF_CONF")) ===" | tee -a "$RESULTS"

# run_one "O3 (baseline)"
# run_one "O2"                          SYSLOG_NG_FILTERX_JIT_PASSES="default<O2>"
# run_one "O1"                          SYSLOG_NG_FILTERX_JIT_PASSES="default<O1>"
# run_one "Os"                          SYSLOG_NG_FILTERX_JIT_PASSES="default<Os>"
# run_one "Oz"                          SYSLOG_NG_FILTERX_JIT_PASSES="default<Oz>"
# run_one "O3 no-aggressive-inline"     SYSLOG_NG_NO_AGGRESSIVE_INLINE=1
# run_one "Os no-aggressive-inline"     SYSLOG_NG_FILTERX_JIT_PASSES="default<Os>" SYSLOG_NG_NO_AGGRESSIVE_INLINE=1
# run_one "Oz no-aggressive-inline"     SYSLOG_NG_FILTERX_JIT_PASSES="default<Oz>" SYSLOG_NG_NO_AGGRESSIVE_INLINE=1
# run_one "O3 inlinehint-threshold=150" SYSLOG_NG_FILTERX_JIT_LLVM_ARGS="-inlinehint-threshold=150"
# run_one "O3 inlinehint-threshold=50"  SYSLOG_NG_FILTERX_JIT_LLVM_ARGS="-inlinehint-threshold=50"
# run_one "O3 inline-threshold=50"      SYSLOG_NG_FILTERX_JIT_LLVM_ARGS="-inline-threshold=50 -inlinehint-threshold=50"
# run_one "O3 no-vectorize"             SYSLOG_NG_FILTERX_JIT_LLVM_ARGS="-vectorize-loops=false -vectorize-slp=false"
# run_one "O3 unroll-threshold=16"      SYSLOG_NG_FILTERX_JIT_LLVM_ARGS="-unroll-threshold=16"
# run_one "O3 codegen-O2"               SYSLOG_NG_FILTERX_JIT_CODEGEN="2 0 1"
# run_one "O3 codegen-O1"               SYSLOG_NG_FILTERX_JIT_CODEGEN="1 0 1"
# run_one "Os codegen-O2"               SYSLOG_NG_FILTERX_JIT_PASSES="default<Os>" SYSLOG_NG_FILTERX_JIT_CODEGEN="2 0 1"
# run_one "Os hint=50"                  SYSLOG_NG_FILTERX_JIT_PASSES="default<Os>" SYSLOG_NG_FILTERX_JIT_LLVM_ARGS="-inlinehint-threshold=50"

# Aggressive inlining is branch-dependent: older branches default to ON and
# honor SYSLOG_NG_NO_AGGRESSIVE_INLINE=1, newer ones default to OFF and honor
# SYSLOG_NG_AGGRESSIVE_INLINE=1.  Set both explicitly so labels stay truthful.
NOAGGR="SYSLOG_NG_NO_AGGRESSIVE_INLINE=1 SYSLOG_NG_AGGRESSIVE_INLINE=0"
AGGR="SYSLOG_NG_NO_AGGRESSIVE_INLINE=0 SYSLOG_NG_AGGRESSIVE_INLINE=1"

run_one "noaggr O3 (baseline)"     $NOAGGR
run_one "aggr O3"                  $AGGR
run_one "noaggr codegen-O2"        $NOAGGR SYSLOG_NG_FILTERX_JIT_CODEGEN="2 0 1"
run_one "noaggr hint=50"           $NOAGGR SYSLOG_NG_FILTERX_JIT_LLVM_ARGS="-inlinehint-threshold=50"
run_one "noaggr inline=50 hint=50" $NOAGGR SYSLOG_NG_FILTERX_JIT_LLVM_ARGS="-inline-threshold=50 -inlinehint-threshold=50"
run_one "noaggr Oz hint=5"         $NOAGGR SYSLOG_NG_FILTERX_JIT_PASSES="default<Oz>" SYSLOG_NG_FILTERX_JIT_LLVM_ARGS="-inlinehint-threshold=5"
run_one "noaggr outliner"          $NOAGGR SYSLOG_NG_FILTERX_JIT_LLVM_ARGS="-enable-machine-outliner=always"
run_one "aggr outliner"            $AGGR SYSLOG_NG_FILTERX_JIT_LLVM_ARGS="-enable-machine-outliner=always"
run_one "aggr hot-cold-split"      $AGGR SYSLOG_NG_FILTERX_JIT_LLVM_ARGS="-hot-cold-split"
run_one "noaggr hot-cold-split"    $NOAGGR SYSLOG_NG_FILTERX_JIT_LLVM_ARGS="-hot-cold-split"

echo "Results: $RESULTS"
echo "Objects: $OBJ_BASE"
