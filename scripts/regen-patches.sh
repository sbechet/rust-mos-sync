#!/usr/bin/env bash
# regen-patches.sh <llvm|rust> [<base-ref>]
#
# Re-exports the commits base..mos of the work tree as patches/<component>/.
# Flags keep diffs between regenerations minimal (PLAN.md §6).
. "$(dirname "$0")/lib.sh"
need git

component="${1:?usage: regen-patches.sh <llvm|rust> [base-ref]}"
base="${2:-base-stable}"
case "$component" in
    llvm) dir="$WORK/llvm-project" ;;
    rust) dir="$WORK/rust" ;;
    *) die "unknown component: $component" ;;
esac
if [ "$component" = llvm ]; then
    out=$(llvm_series_dir "${base#base-}" --allow-missing)
else
    out=$(rust_series_dir "${base#base-}" --allow-missing)
fi

mkdir -p "$out"
find "$out" -maxdepth 1 -name '*.patch' -delete
git -C "$dir" format-patch -q --no-numbered --zero-commit --no-signature \
    --full-index --binary -o "$out" "$base..mos"
log "$component: $(find "$out" -maxdepth 1 -name '*.patch' | wc -l) patch(es) written to patches/$component"
