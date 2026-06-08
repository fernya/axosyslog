#!/bin/bash
# Measure generic (opaque) vs. type-specific JIT helper calls per commit.
# Generic calls go through vtables; typed calls are direct dispatch.
# Both emit through fx_jit_emit_extern_call(), which we instrument.

REPO=/home/bferencz/Development/axosyslog-jit
BUILD=$REPO/build
PERF_CONF=/home/bferencz/Development/fernya-jit-tests/perf.conf
FFI_C=$REPO/lib/filterx/jit/ffi.c
JIT_C=$REPO/lib/filterx/jit/jit.c
SCRIPT_SELF=$(readlink -f "$0")
ORIG_BRANCH=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
TIP_HASH=$(git -C "$REPO" rev-parse --short HEAD)
TIP_DESC=$(git -C "$REPO" log -1 --format=%s HEAD)
RESULTS_FILE=/tmp/opaque_call_results.txt
export SYSLOG_NG_FILTERX_JIT_LLVM_ARGS="${SYSLOG_NG_FILTERX_JIT_LLVM_ARGS:-}"
export SYSLOG_NG_FILTERX_JIT_CODEGEN="${SYSLOG_NG_FILTERX_JIT_CODEGEN:-}"
export SYSLOG_NG_FILTERX_JIT_PASSES="${SYSLOG_NG_FILTERX_JIT_PASSES:-}"

# Commits from parent-of-baseline through tip
COMMITS=(
  "56265ebd4:no tm no tmc (baseline)"
  "$TIP_HASH:$TIP_DESC (tip)"
)

# Those commits should be measured with SYSLOG_NG_NO_AGGRESSIVE_INLINE env set to 0/1
INLINER_TUNING_COMMITS="$TIP_HASH"

> "$RESULTS_FILE"
echo "=== Generic vs. typed JIT extern calls per commit (perf.conf) ===" | tee -a "$RESULTS_FILE"
printenv | grep "^SYSLOG_NG_" | sort | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

inject_extern_call_logger() {
  # Instrument fx_jit_emit_extern_call to log every emitted call name
  python3 - "$FFI_C" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    src = f.read()
# Insert fprintf before the final return in fx_jit_emit_extern_call
patched = src.replace(
    'return _emit_call(jit, call, args, param_count);\n}',
    'fprintf(stderr, "EXTERN_CALL %s\\n", name);\n  return _emit_call(jit, call, args, param_count);\n}',
    1
)
if '#include <stdio.h>' not in patched and 'fprintf' in patched:
    patched = patched.replace('#include <stdarg.h>', '#include <stdarg.h>\n#include <stdio.h>')
with open(path, 'w') as f:
    f.write(patched)
print("OK" if "EXTERN_CALL" in patched else "FAILED")
PYEOF
}

inject_size_instrumentation() {
  python3 - "$JIT_C" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    src = f.read()

# Need Object.h for the LLVMBinaryRef section-iteration API (LLVM 14+)
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
    '    LLVMMemoryBufferRef _buf = NULL; char *_em = NULL; size_t _mcs = 0;\n'
    '    if (!LLVMTargetMachineEmitToMemoryBuffer(self->tm, _mc, LLVMObjectFile, &_em, &_buf)) {\n'
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
    '  LLVMOrcThreadSafeModuleRef ts_mod = LLVMOrcCreateNewThreadSafeModule(self->mod, self->ts_ctx);\n'
)
patched = src.replace(needle, patch, 1)
with open(path, 'w') as f:
    f.write(patched)
print("OK" if patched != src else "FAILED")
PYEOF
}

GENERIC_HELPERS="fx_jit_do_getattr fx_jit_do_setattr fx_jit_do_nullv_setattr fx_jit_do_plus fx_jit_do_assign fx_jit_do_nullv_assign fx_jit_do_get_subscript fx_jit_do_set_subscript fx_jit_do_nullv_set_subscript"
TYPED_HELPERS="fx_jit_do_getattr_dict fx_jit_do_setattr_dict fx_jit_do_nullv_setattr_dict fx_jit_do_plus_string fx_jit_do_plus_int fx_jit_do_get_subscript_dict fx_jit_do_get_subscript_dict_string_key fx_jit_do_get_subscript_list fx_jit_do_set_subscript_dict fx_jit_do_set_subscript_list fx_jit_do_nullv_set_subscript_dict fx_jit_do_nullv_set_subscript_list"

is_inliner_tuning_commit() {
  local hash="$1"
  for c in $INLINER_TUNING_COMMITS; do
    [[ "$hash" == "$c"* ]] && return 0
  done
  return 1
}

# Run syslog-ng once, collect and print the extern-call tally.
# $1: label suffix shown in output (e.g. "" or "  [NO_AGGRESSIVE_INLINE=1]")
# $2: value for SYSLOG_NG_NO_AGGRESSIVE_INLINE ("0", "1", or "" to leave unset)
run_measurement() {
  local label_suffix="$1"
  local no_aggr="$2"

  local TMPOUT
  TMPOUT=$(mktemp)

  if [ -n "$no_aggr" ]; then
    SYSLOG_NG_NO_AGGRESSIVE_INLINE="$no_aggr" \
      timeout 8 "$BUILD/syslog-ng/syslog-ng" -Fe -f "$PERF_CONF" >"$TMPOUT" 2>&1 || true
    echo "  [SYSLOG_NG_NO_AGGRESSIVE_INLINE=$no_aggr]$label_suffix" | tee -a "$RESULTS_FILE"
  else
    timeout 8 "$BUILD/syslog-ng/syslog-ng" -Fe -f "$PERF_CONF" >"$TMPOUT" 2>&1 || true
  fi

  local IR_TOTAL=0
  while IFS= read -r _line; do
    IR_TOTAL=$((IR_TOTAL + ${_line#IR_SIZE }))
  done < <(grep "^IR_SIZE " "$TMPOUT" 2>/dev/null)

  local MC_TOTAL=0
  while IFS= read -r _line; do
    MC_TOTAL=$((MC_TOTAL + ${_line#MC_SIZE }))
  done < <(grep "^MC_SIZE " "$TMPOUT" 2>/dev/null)

  local GENERIC_TOTAL=0 TYPED_TOTAL=0
  local GENERIC_BREAKDOWN="" TYPED_BREAKDOWN=""

  for fn in $GENERIC_HELPERS; do
    local C
    C=$(grep -c "^EXTERN_CALL ${fn}$" "$TMPOUT" 2>/dev/null) || C=0
    [ "$C" -gt 0 ] && GENERIC_TOTAL=$((GENERIC_TOTAL + C)) && GENERIC_BREAKDOWN="$GENERIC_BREAKDOWN ${fn}:${C}"
  done

  for fn in $TYPED_HELPERS; do
    local C
    C=$(grep -c "^EXTERN_CALL ${fn}$" "$TMPOUT" 2>/dev/null) || C=0
    [ "$C" -gt 0 ] && TYPED_TOTAL=$((TYPED_TOTAL + C)) && TYPED_BREAKDOWN="$TYPED_BREAKDOWN ${fn}:${C}"
  done

  local ALL_EXTERN
  ALL_EXTERN=$(grep -c "^EXTERN_CALL " "$TMPOUT" 2>/dev/null) || ALL_EXTERN=0

  echo "  generic=$GENERIC_TOTAL  typed=$TYPED_TOTAL  total_extern=$ALL_EXTERN  ir_size=$IR_TOTAL  mc_size=$MC_TOTAL" | tee -a "$RESULTS_FILE"
  [ -n "$GENERIC_BREAKDOWN" ] && echo "  generic_breakdown:$GENERIC_BREAKDOWN" | tee -a "$RESULTS_FILE"
  [ -n "$TYPED_BREAKDOWN" ]  && echo "  typed_breakdown: $TYPED_BREAKDOWN"  | tee -a "$RESULTS_FILE"

  rm -f "$TMPOUT"
}

for entry in "${COMMITS[@]}"; do
  HASH="${entry%%:*}"
  DESC="${entry#*:}"
  echo "--- $HASH: $DESC ---" | tee -a "$RESULTS_FILE"

  # Restore instrumented files then switch commit.
  # Back up this script first: git checkout -f would overwrite it otherwise.
  cp "$SCRIPT_SELF" /tmp/_measure_opaque_calls_script_backup.sh
  git -C "$REPO" checkout -- lib/filterx/jit/ffi.c lib/filterx/jit/jit.c 2>/dev/null || true
  git -C "$REPO" checkout -f "$HASH" --quiet
  mkdir -p "$(dirname "$SCRIPT_SELF")"
  cp /tmp/_measure_opaque_calls_script_backup.sh "$SCRIPT_SELF"

  STATUS=$(inject_extern_call_logger)
  if [ "$STATUS" != "OK" ]; then
    echo "  SKIP: instrumentation injection failed" | tee -a "$RESULTS_FILE"
    echo "" | tee -a "$RESULTS_FILE"
    continue
  fi
  touch "$FFI_C"

  SIZE_STATUS=$(inject_size_instrumentation)
  if [ "$SIZE_STATUS" = "OK" ]; then
    touch "$JIT_C"
  else
    echo "  WARN: size instrumentation injection failed (ir_size/mc_size will be 0)" | tee -a "$RESULTS_FILE"
  fi

  echo -n "  Building... " | tee -a "$RESULTS_FILE"
  T0=$SECONDS
  if ! make -C "$BUILD" -j$(nproc) syslog-ng >/tmp/build_stdout.txt 2>/tmp/build_stderr.txt; then
    echo "FAILED" | tee -a "$RESULTS_FILE"
    grep "error:" /tmp/build_stderr.txt | head -3 | tee -a "$RESULTS_FILE"
    echo "" | tee -a "$RESULTS_FILE"
    continue
  fi
  echo "done in $((SECONDS-T0))s" | tee -a "$RESULTS_FILE"

  if is_inliner_tuning_commit "$HASH"; then
    run_measurement "" "0"
    run_measurement "" "1"
  else
    run_measurement
  fi

  echo "" | tee -a "$RESULTS_FILE"
done

echo "=== Summary ===" | tee -a "$RESULTS_FILE"
grep -E "^---|  generic=" "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

# Restore
git -C "$REPO" checkout -- lib/filterx/jit/ffi.c lib/filterx/jit/jit.c 2>/dev/null || true
git -C "$REPO" checkout -f "$ORIG_BRANCH" --quiet
echo "Restored to branch: $ORIG_BRANCH" | tee -a "$RESULTS_FILE"
echo "Results: $RESULTS_FILE"
