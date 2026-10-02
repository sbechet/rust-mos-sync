#!/usr/bin/env bash
# lit-diag.sh
#
# After a failed tier 1 (test.sh llvm): replays each CodeGen/MOS .ll test that
# failed and is not in the series' KNOWN_LIT_FAILURES with
# `llc -print-after-all`, so a "cannot select"/"unable to legalize" can be
# traced to the pass that produced the offending instruction without a local
# LLVM build. Output: $WORK/lit-diag-<test>.log (last 600 lines each, at most 4
# tests). Never fails.
. "$(dirname "$0")/lib.sh"

llc="$WORK/llvm-build/bin/llc"
log="$WORK/lit-CodeGen-MOS.log"
[ -x "$llc" ] && [ -f "$log" ] || { log "nothing to diagnose"; exit 0; }
series_dir=$(llvm_series_dir "${CHANNEL:-stable}" --allow-missing)
known=""
[ -f "$series_dir/KNOWN_LIT_FAILURES" ] && known=$(grep -v '^[[:space:]]*\(#\|$\)' "$series_dir/KNOWN_LIT_FAILURES")

n=0
while IFS= read -r t; do
    grep -qxF "$t" <<<"$known" && continue
    f="$WORK/llvm-project/llvm/test/${t#LLVM :: }"
    case "$f" in *.ll) ;; *) continue ;; esac
    [ "$n" -lt 4 ] || break
    n=$((n + 1))
    out="$WORK/lit-diag-$(basename "$f").log"
    log "replaying $(basename "$f") with -print-after-all -> $out"
    { "$llc" -verify-machineinstrs -print-after-all < "$f" 2>&1 >/dev/null || true; } | tail -600 > "$out"
done < <(sed -n '/^Failed Tests/,/^$/p' "$log" | sed -n 's/^  \(LLVM :: .*\)$/\1/p')
exit 0
