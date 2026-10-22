#!/usr/bin/env bash
# sync-mos-backend.sh <stable|beta>
#
# PLAN.md §7.3 (Phase 4): brings the MOS backend in patches/llvm/<NN.N>/ up
# to date with new llvm-mos commits, without involving Claude Code and
# without ever blocking - anything that does not work yet is deferred, not
# fixed. Operates on $WORK/llvm-project's `mos` branch (fetch.sh + apply.sh
# must already have put it at base-<channel> + the current series, same
# precondition as build-llvm.sh).
#
#   1. List llvm-mos commits since llvm_mos.last_synced that touch MOS paths
#      (llvm/lib/Target/MOS, llvm/test/CodeGen/MOS, llvm/test/MC/MOS), plus
#      every commit still in llvm_mos.deferred from a previous run (a later
#      commit may fix what blocked it - same idea as llvm-bump.sh §7.4 step
#      5), all in their original upstream order.
#   2. For each, in order: a "Merge from upstream LLVM" commit (2 parents) is
#      not cherry-picked whole - that would drag in llvm-mos's own unrelated
#      upstream-sync history. Only its MOS-path diff against its first
#      parent is applied (`git diff <parent1> <merge> -- <MOS paths>`); a
#      regular commit is applied whole (`git am`), non-MOS files and all -
#      MOS support occasionally has to touch shared LLVM code (the existing
#      patches/llvm/*/0001 does too), and trimming it risks an incomplete
#      feature, not a safer one.
#   3. A commit that does not apply (`git apply --check -3` fails) is
#      deferred immediately. One that applies is built incrementally
#      (`ninja -C $WORK/llvm-build install`, configured on demand by
#      `build-llvm.sh --configure`) and tier 1 is run
#      (`test.sh llvm`); either failing reverts the commit and defers it.
#      Deferring never blocks the loop or involves Claude Code (PLAN.md §8
#      is sync-rust/llvm-bump conflicts only).
#   4. llvm_mos.last_synced advances to the newest commit considered (applied
#      or deferred - a commit is never reconsidered just because it failed);
#      llvm_mos.deferred is rewritten to exactly the ones still unresolved.
#
# Does not call regen-patches.sh or build a toolchain: the caller (workflow)
# does that, then runs the full test tiers for the PR.
. "$(dirname "$0")/lib.sh"
need git ninja

channel="${1:?usage: sync-mos-backend.sh <stable|beta>}"
src="$WORK/llvm-project"
build="$WORK/llvm-build"
[ -d "$src/.git" ] || die "$src missing; run fetch.sh llvm and apply.sh llvm first"
[ "$(git -C "$src" rev-parse --abbrev-ref HEAD)" = mos ] || die "$src is not on branch mos; run apply.sh llvm first"
git -C "$src" diff --quiet HEAD && [ -z "$(git -C "$src" status --porcelain)" ] \
    || die "$src has uncommitted changes"

last_synced=$(ver_get llvm_mos.last_synced)
[ -n "$last_synced" ] || die "versions.toml llvm_mos.last_synced is empty"
mapfile -t deferred_before < <(ver_get llvm_mos.deferred)

mos_paths=(llvm/lib/Target/MOS llvm/test/CodeGen/MOS llvm/test/MC/MOS)

# --- 1. candidate list: deferred-but-not-yet-superseded + new, chronological
hist="$WORK/sync-mos-backend-src.git"   # dedicated, scoped mirror - never
# the generic $LLVM_MOS_URL remote already on $src: that one has no
# shallow-since/depth limit, and a single missing object on it triggers an
# unscoped promisor fetch of llvm-mos's *entire* history (hundreds of
# thousands of commits - it merges upstream LLVM continuously). Patches are
# generated here as plain text and applied to $src with `git am`/`git
# apply`, which never touches $src's own object store against llvm-mos.
if [ ! -d "$hist" ]; then
    git init -q --bare "$hist"
    git -C "$hist" remote add origin "$LLVM_MOS_URL"
fi
git -C "$hist" fetch -q --depth=1 --filter=blob:none origin "$last_synced" \
    || die "llvm_mos.last_synced ($last_synced) not found on llvm-mos; was it rewritten?"
since=$(git -C "$hist" log -1 --format=%cI "$last_synced")
log "fetching llvm-mos main since $since (last_synced $last_synced)"
git -C "$hist" fetch -q --filter=blob:none "--shallow-since=$since" \
    origin "+refs/heads/main:refs/remotes/origin/main"

mapfile -t new_commits < <(git -C "$hist" rev-list --reverse "$last_synced..refs/remotes/origin/main" \
    -- "${mos_paths[@]}")

# Deferred commits from before are already ancestors of last_synced, so they
# would not show up in the range above; re-fetch them by sha (they are
# already local objects from a previous run's $hist, but $hist may be a
# fresh clone in CI) and merge both lists by commit date.
candidates=()
if [ ${#deferred_before[@]} -gt 0 ] && [ -n "${deferred_before[0]}" ]; then
    # --depth=2, not 1: diffing a (possibly merge) commit needs its immediate
    # parent(s) too, which --depth=1 would truncate away as a shallow
    # boundary right at the wanted commit itself.
    git -C "$hist" fetch -q --depth=2 --filter=blob:none origin "${deferred_before[@]}" \
        || die "a previously deferred commit is no longer on llvm-mos main; resolve llvm_mos.deferred by hand"
    mapfile -t candidates < <(
        { printf '%s\n' "${deferred_before[@]}"; printf '%s\n' "${new_commits[@]}"; } \
        | while read -r c; do [ -n "$c" ] && git -C "$hist" log -1 --format="%ct $c" "$c"; done \
        | sort -n | awk '{print $2}'
    )
else
    candidates=("${new_commits[@]}")
fi

log "${#candidates[@]} candidate commit(s) (${#deferred_before[@]} retried, $((${#candidates[@]} - ${#deferred_before[@]})) new)"
if [ ${#candidates[@]} -eq 0 ]; then
    log "nothing to do"
    exit 0
fi

# --- 2-3. apply, build, test, defer -----------------------------------
report="$WORK/sync-mos-backend-report.md"
: > "$report"
applied=()
deferred=()
newest_considered="$last_synced"

defer() {
    deferred+=("$1")
    printf -- '- `%s` deferred: %s\n' "$(git -C "$hist" log -1 --format='%h %s' "$1")" "$2" >> "$report"
}

for c in "${candidates[@]}"; do
    subject=$(git -C "$hist" log -1 --format=%s "$c")
    parents=($(git -C "$hist" log -1 --format=%P "$c"))
    patch="$WORK/sync-mos-backend.patch"
    is_merge=0
    if [ ${#parents[@]} -gt 1 ]; then
        is_merge=1
        # Only the MOS-path delta against the first parent: the merge's
        # other content is llvm-mos's own unrelated upstream sync.
        git -C "$hist" diff --binary --full-index "${parents[0]}" "$c" -- "${mos_paths[@]}" > "$patch"
    else
        git -C "$hist" format-patch -1 --stdout --binary --full-index "$c" > "$patch"
    fi

    if [ ! -s "$patch" ]; then
        log "$c ($subject): empty diff on MOS paths after merge-noise filtering, skipping"
        newest_considered="$c"
        continue
    fi

    # Only meaningful for a regular commit, applied whole: a merge commit's
    # patch above already excludes non-MOS paths on purpose.
    outside=""
    [ "$is_merge" = 1 ] || outside=$(git -C "$hist" diff --name-only "${parents[0]}" "$c" -- . \
        | grep -vE '^(llvm/lib/Target/MOS/|llvm/test/(CodeGen|MC)/MOS/)' || true)

    ok=1
    if [ "$is_merge" = 1 ]; then
        git -C "$src" apply --check -3 "$patch" 2>"$WORK/sync-mos-backend-apply.log" \
            && git -C "$src" apply -3 "$patch" \
            && git -C "$src" -c user.name=rust-mos-sync -c user.email=rust-mos-sync@localhost \
                   commit -q -am "MOS: $subject" \
            || ok=0
    else
        git -C "$src" -c user.name=rust-mos-sync -c user.email=rust-mos-sync@localhost \
               am -3 --keep-cr --committer-date-is-author-date "$patch" \
               >"$WORK/sync-mos-backend-apply.log" 2>&1 \
            || ok=0
    fi
    # A failed attempt may leave the tree conflicted (apply -3) or rebasing
    # (am -3); either way, back out completely before the next candidate.
    # $src is always on branch `mos` (asserted above and never left), so
    # undoing is always relative to its own HEAD, never a separate ref.
    if [ "$ok" = 0 ]; then
        git -C "$src" am --abort >/dev/null 2>&1 || true
        git -C "$src" reset --hard HEAD >/dev/null 2>&1
        git -C "$src" clean -qfd
        defer "$c" "does not apply cleanly"
        newest_considered="$c"
        continue
    fi
    # A clean 3-way apply can still leave literal conflict markers in a file
    # without failing (git-apply quirk): refuse to build/test that.
    if git -C "$src" grep -lq -e '^<<<<<<<' -e '^=======$' -e '^>>>>>>>' -- "${mos_paths[@]}" 2>/dev/null; then
        git -C "$src" reset --hard HEAD~1 >/dev/null 2>&1
        git -C "$src" clean -qfd
        defer "$c" "3-way apply left conflict markers"
        newest_considered="$c"
        continue
    fi

    build=$("$ROOT/scripts/build-llvm.sh" --configure "$channel")
    [ "$build" = "$WORK/llvm-build" ] || die "unexpected build dir $build"
    if ! ninja -C "$build" -j "$JOBS" install >"$WORK/sync-mos-backend-build.log" 2>&1; then
        git -C "$src" reset --hard HEAD~1 >/dev/null 2>&1
        defer "$c" "breaks the LLVM build (log: work/sync-mos-backend-build.log)"
        newest_considered="$c"
        continue
    fi
    if ! "$ROOT/scripts/test.sh" llvm >"$WORK/sync-mos-backend-test.log" 2>&1; then
        git -C "$src" reset --hard HEAD~1 >/dev/null 2>&1
        defer "$c" "breaks a MOS lit test (log: work/sync-mos-backend-test.log)"
        newest_considered="$c"
        continue
    fi

    applied+=("$c")
    newest_considered="$c"
    line="- \`$(git -C "$hist" log -1 --format='%h %s' "$c")\`"
    [ -n "$outside" ] && line="$line (also touches outside the MOS backend: $(echo "$outside" | tr '\n' ' '))"
    printf '%s\n' "$line" >> "$report"
    log "applied $c ($subject)"
done

ver_set llvm_mos.last_synced "$newest_considered"
if [ ${#deferred[@]} -gt 0 ]; then
    list=$(printf '"%s",' "${deferred[@]}")
    ver_set llvm_mos.deferred "raw:[${list%,}]"
else
    ver_set llvm_mos.deferred "raw:[]"
fi

{
    echo
    echo "**${#applied[@]} applied, ${#deferred[@]} deferred** out of ${#candidates[@]} candidate commit(s)."
} >> "$report"
log "${#applied[@]} applied, ${#deferred[@]} deferred; last_synced -> $newest_considered"
