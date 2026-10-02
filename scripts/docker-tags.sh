#!/usr/bin/env bash
# docker-tags.sh <stable|beta> <release:true|false> <sha>
#
# Prints the ghcr.io/<owner>/rust-mos tags to push for a toolchain image, one
# per line (owner from $GITHUB_REPOSITORY_OWNER, default sbechet).
#
#   always            <channel>               moving: latest of that channel
#                     sha-<commit>            this repo's commit, for debugging
#   release only      stable: <X.Y.Z>-mos.<N>        immutable  e.g. 1.99.0-mos.1
#                             <X.Y>                  moving: latest of that minor
#                     beta:   <X.Y.Z>-beta-mos.<c7>  immutable  e.g. 1.100.0-beta-mos.e3feeb5
#
# <N> is release.mos_revision; a beta has no revision counter, it is the first
# 7 characters of the Rust beta commit it was built from. The channel is
# therefore readable in every versioned tag ("-beta-" or none = stable) and the
# Rust version in every one. LLVM version and commit are image labels.
. "$(dirname "$0")/lib.sh"

channel="${1:?usage: docker-tags.sh <stable|beta> <true|false> <sha>}"
release="${2:?}"
sha="${3:?}"
repo="ghcr.io/${GITHUB_REPOSITORY_OWNER:-sbechet}/rust-mos"

echo "$repo:$channel"
echo "$repo:sha-$sha"
[ "$release" = true ] || exit 0

case "$channel" in
    stable)
        tag=$(ver_get rust.stable.tag)
        echo "$repo:$tag-mos.$(ver_get release.mos_revision)"
        echo "$repo:$(cut -d. -f1,2 <<<"$tag")"
        ;;
    beta)
        tag=$(ver_get rust.beta.tag)            # e.g. 1.100.0-beta
        commit=$(ver_get rust.beta.commit)
        echo "$repo:$tag-mos.${commit:0:7}"
        ;;
    *) die "unknown channel: $channel" ;;
esac
