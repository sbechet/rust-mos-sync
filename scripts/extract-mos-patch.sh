#!/usr/bin/env bash
# extract-mos-patch.sh <llvm-branch> [<merge-commit>]
#
# Picks the llvm-mos "merge from upstream" commit closest to (and, when
# possible, not newer than) the upstream point Rust's LLVM branch was cut from,
# then writes the MOS delta (merge commit vs. its upstream parent) as a single
# patch into $WORK/mos-extract/mos.patch. PLAN.md §3.1 and §7.4 steps 1-3.
#
# Prints, on stdout, "<merge> <upstream-parent>". Files touched outside the
# usual MOS areas are listed in $WORK/mos-extract/outside-mos.txt for the PR.
. "$(dirname "$0")/lib.sh"
need git

branch="${1:?usage: extract-mos-patch.sh <rustc/NN.N-...> [merge-commit]}"
merge="${2:-}"

hist="$WORK/llvm-history.git"   # commits only (tree:0): cheap ancestry queries
out="$WORK/mos-extract"
mkdir -p "$out"

if [ ! -d "$hist" ]; then
    git init -q --bare "$hist"
    git -C "$hist" remote add mos "$LLVM_MOS_URL"
    git -C "$hist" remote add rust "$RUST_LLVM_URL"
fi
log "fetching commit history (trees and blobs omitted)"
git -C "$hist" fetch -q --filter=tree:0 mos '+refs/heads/main:refs/remotes/mos/main'
git -C "$hist" fetch -q --filter=tree:0 rust "+refs/heads/$branch:refs/remotes/rust/$branch"

base=$(git -C "$hist" merge-base "mos/main" "rust/$branch")
log "Rust branch $branch forked from upstream $(git -C "$hist" log -1 --format='%h (%cs)' "$base")"

# A commit that exists only on the llvm-mos side (MOS fix, 2026-01-03). Any
# llvm-mos-side parent of a later merge contains it; upstream never does. It
# tells merge parents apart even when they are swapped (e.g. 43815c2f).
MOS_MARKER=00688ef2227807758d8ca1021a70d3e950c5a115

upstream_parent() {
    local p
    for p in $(git -C "$hist" log -1 --format=%P "$1"); do
        git -C "$hist" merge-base --is-ancestor "$MOS_MARKER" "$p" || { echo "$p"; return; }
    done
}

if [ -z "$merge" ]; then
    # Newest first-parent merge whose upstream parent is not newer than $base.
    while read -r m; do
        p=$(upstream_parent "$m")
        if [ -n "$p" ] && git -C "$hist" merge-base --is-ancestor "$p" "$base"; then
            merge="$m"; break
        fi
    done < <(git -C "$hist" log --first-parent --merges --format=%H mos/main)
    [ -n "$merge" ] || die "no llvm-mos merge found that is not newer than $base"
fi
parent=$(upstream_parent "$merge")
[ -n "$parent" ] || die "cannot determine upstream parent of $merge"
behind=$(git -C "$hist" rev-list --count "$parent..$base")
log "base merge $(git -C "$hist" log -1 --format='%h %cs' "$merge"), upstream parent $(git -C "$hist" log -1 --format='%h %cs' "$parent") ($behind upstream commits behind the fork point)"

# Content diff: shallow, blob-less fetch of the two commits, blobs on demand.
ex="$WORK/llvm-mos-extract.git"
if [ ! -d "$ex" ]; then
    git init -q --bare "$ex"
    git -C "$ex" remote add origin "$LLVM_MOS_URL"
    git -C "$ex" config remote.origin.promisor true
    git -C "$ex" config remote.origin.partialclonefilter blob:none
    git -C "$ex" config extensions.partialClone origin
fi
git -C "$ex" fetch -q --depth=1 --filter=blob:none origin "$merge" "$parent"

# Excluded: upstream-irrelevant repo plumbing and subprojects we never build.
excludes=(':!.github' ':!lldb' ':!local-bin' ':!README.md' ':!CONTRIBUTING.md'
          ':!AUTHORS' ':!NOTICE')
git -C "$ex" diff --binary --full-index "$parent" "$merge" -- . "${excludes[@]}" > "$out/mos.patch"
git -C "$ex" diff --name-only "$parent" "$merge" -- . "${excludes[@]}" \
    | grep -vE '^(llvm/lib/Target/MOS/|llvm/test/[^/]+/MOS/|clang/|lld/)' > "$out/outside-mos.txt" || true
log "patch: $(git -C "$ex" diff --shortstat "$parent" "$merge" -- . "${excludes[@]}")"
log "$(wc -l < "$out/outside-mos.txt") files outside MOS/clang/lld listed in $out/outside-mos.txt"

echo "$merge $parent"
