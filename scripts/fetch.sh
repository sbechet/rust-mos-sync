#!/usr/bin/env bash
# fetch.sh <llvm|rust|sdk> [<channel>]
#
# Fetches the upstream sources pinned in versions.toml into $WORK:
#   llvm -> $WORK/llvm-project  rust-lang/llvm-project at rust.<channel>.llvm_commit
#   rust -> $WORK/rust          rust-lang/rust at rust.<channel>.tag (commit for beta)
#   sdk  -> $WORK/llvm-mos-sdk  llvm-mos-sdk at llvm_mos_sdk.commit (main if empty)
# Shallow (depth 1); objects already present are never fetched again.
# The llvm tree also knows llvm-mos as a promisor remote, so `git am -3` can
# lazily fetch the preimage blobs of the MOS patch.
. "$(dirname "$0")/lib.sh"
need git

component="${1:?usage: fetch.sh <llvm|rust|sdk> [stable|beta]}"
channel="${2:-stable}"

# ensure_repo <dir> <remote-name> <url> [<extra-remote> <url>]...
ensure_repo() {
    local dir="$1"; shift
    if [ ! -d "$dir/.git" ]; then
        git init -q "$dir"
        git -C "$dir" config advice.detachedHead false
    fi
    while [ $# -gt 0 ]; do
        git -C "$dir" remote get-url "$1" >/dev/null 2>&1 || git -C "$dir" remote add "$1" "$2"
        shift 2
    done
}

# fetch_commit <dir> <remote> <commit-or-ref>
fetch_commit() {
    local dir="$1" remote="$2" ref="$3"
    if git -C "$dir" cat-file -e "$ref^{commit}" 2>/dev/null; then
        log "$(basename "$dir"): $ref already present"
    else
        log "$(basename "$dir"): fetching $ref from $remote"
        git -C "$dir" fetch -q --depth=1 "$remote" "$ref"
    fi
}

case "$component" in
    llvm)
        commit=$(ver_get "rust.$channel.llvm_commit")
        [ -n "$commit" ] || die "rust.$channel.llvm_commit is empty"
        dir="$WORK/llvm-project"
        ensure_repo "$dir" rust "$RUST_LLVM_URL" mos "$LLVM_MOS_URL"
        git -C "$dir" config remote.mos.promisor true
        git -C "$dir" config remote.mos.partialclonefilter blob:none
        git -C "$dir" config extensions.partialClone mos
        fetch_commit "$dir" rust "$commit"
        git -C "$dir" tag -f "base-$channel" "$commit" >/dev/null
        ;;
    rust)
        if [ "$channel" = beta ]; then ref=$(ver_get rust.beta.commit); else ref="refs/tags/$(ver_get rust.stable.tag)"; fi
        dir="$WORK/rust"
        ensure_repo "$dir" origin "$RUST_URL"
        if [ "$channel" = beta ]; then
            fetch_commit "$dir" origin "$ref"
            git -C "$dir" tag -f "base-$channel" "$ref" >/dev/null
        else
            tag="${ref#refs/tags/}"
            git -C "$dir" rev-parse -q --verify "refs/tags/$tag" >/dev/null \
                || git -C "$dir" fetch -q --depth=1 origin "$ref:$ref"
            git -C "$dir" tag -f "base-$channel" "$tag^{commit}" >/dev/null
        fi
        ;;
    sdk)
        commit=$(ver_get llvm_mos_sdk.commit)
        dir="$WORK/llvm-mos-sdk"
        ensure_repo "$dir" origin "$LLVM_MOS_SDK_URL"
        if [ -z "$commit" ]; then
            git -C "$dir" fetch -q --depth=1 origin main
            commit=$(git -C "$dir" rev-parse FETCH_HEAD)
            warn "llvm_mos_sdk.commit unset, using main ($commit)"
        else
            fetch_commit "$dir" origin "$commit"
        fi
        git -C "$dir" checkout -q --force "$commit"
        ;;
    *) die "unknown component: $component" ;;
esac
