#!/usr/bin/env bash
# apply.sh <llvm|rust> <base-ref>
#
# Creates a fresh branch `mos` from <base-ref> in the work tree and applies the
# patches/<component>/*.patch series with `git am -3`. On conflict the tree is
# left in the conflicted state and the script exits 2 (PLAN.md §6).
. "$(dirname "$0")/lib.sh"
need git

component="${1:?usage: apply.sh <llvm|rust> <base-ref>}"
base="${2:?usage: apply.sh <llvm|rust> <base-ref>}"
case "$component" in
    llvm) dir="$WORK/llvm-project" ;;
    rust) dir="$WORK/rust" ;;
    *) die "unknown component: $component" ;;
esac
[ -d "$dir/.git" ] || die "$dir missing; run scripts/fetch.sh $component first"

git -C "$dir" am --abort >/dev/null 2>&1 || true
git -C "$dir" checkout -q --force -B mos "$base"
git -C "$dir" clean -qfdx -e /build

mapfile -t series < <(find "$ROOT/patches/$component" -maxdepth 1 -name '*.patch' | sort)
if [ ${#series[@]} -eq 0 ]; then
    log "no patches for $component"
    exit 0
fi

log "applying ${#series[@]} $component patch(es) on $base"
if ! git -C "$dir" -c user.name=rust-mos-sync -c user.email=rust-mos-sync@localhost \
        am -3 --keep-cr --committer-date-is-author-date "${series[@]}"; then
    warn "conflict while applying $component patches; tree left in $dir"
    git -C "$dir" status --short | grep -E '^(UU|AA|DU|UD|DD|AU|UA) ' >&2 || true
    exit "$EXIT_CONFLICT"
fi
log "$component: series applied, HEAD $(git -C "$dir" rev-parse --short HEAD)"
