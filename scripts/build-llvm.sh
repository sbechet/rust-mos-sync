#!/usr/bin/env bash
# build-llvm.sh [--key|--package] [<channel>]
#
# Provides the patched LLVM in $CACHE/llvm/<key>, where <key> hashes the Rust
# LLVM commit, the patch series and the build configuration (PLAN.md §3.4),
# and prints that prefix. In order:
#   1. local cache hit;
#   2. download of llvm-<key>-<host>.tar.xz from $LLVM_CACHE_URL (the
#      `llvm-cache` release of the GitHub repository);
#   3. build of $WORK/llvm-project (branch `mos`, see apply.sh).
# --key       only print the key.
# --package   write $WORK/llvm-<key>-<host>.tar.xz from the local install and
#             print its path (for upload to the llvm-cache release).
# --configure cmake-configure $WORK/llvm-build (a no-op if already configured)
#             without building or checking the base+series invariant, and
#             print its path. For sync-mos-backend.sh's per-commit rebuild
#             loop (PLAN.md §7.3), which runs `mos` ahead of the series on
#             purpose while it tries new llvm-mos commits.
#
# Environment:
#   LLVM_PROJECTS    default "" (clang and lld come from the llvm-mos SDK)
#   LLVM_NO_DOWNLOAD set to 1 to skip step 2
#   LLVM_KEEP_GOING  set to 1 to let ninja report every failing file
#   JOBS             compile jobs (default: nproc); LINK_JOBS default 1
. "$(dirname "$0")/lib.sh"
need python3 sha256sum

mode=build
case "${1:-}" in
    --key) mode=key; shift ;;
    --package) mode=package; shift ;;
    --configure) mode=configure; shift ;;
esac
channel="${1:-stable}"
src="$WORK/llvm-project"
build="$WORK/llvm-build"
commit=$(ver_get "rust.$channel.llvm_commit")
host=$(host_triple)

# MOS is an experimental target in llvm-mos: it must go through
# LLVM_EXPERIMENTAL_TARGETS_TO_BUILD, not LLVM_TARGETS_TO_BUILD.
targets="X86"
case "$(uname -m)" in aarch64|arm64) targets="X86;AArch64" ;; esac
experimental="MOS"
projects="${LLVM_PROJECTS-}"
LINK_JOBS="${LINK_JOBS:-1}"

# Everything that influences the produced binaries goes into the key.
config="targets=$targets experimental=$experimental projects=$projects host=$host"
series_dir=$(llvm_series_dir "$channel")
patches_hash=$(cat "$series_dir"/*.patch 2>/dev/null | sha256sum | cut -c1-16)
key="$(printf '%s\n%s\n%s\n' "$commit" "$patches_hash" "$config" | sha256sum | cut -c1-16)"
prefix="$CACHE/llvm/$key"
asset="llvm-$key-$host.tar.xz"

case "$mode" in
    key) echo "$key"; exit 0 ;;
    package)
        [ -f "$prefix/.complete" ] || die "no complete LLVM install for key $key"
        need tar xz
        tar -C "$prefix" -cf - . | xz -T0 -6 > "$WORK/$asset.tmp"
        mv "$WORK/$asset.tmp" "$WORK/$asset"
        log "packaged $WORK/$asset ($(du -h "$WORK/$asset" | cut -f1))"
        echo "$WORK/$asset"; exit 0 ;;
    configure)
        # Before the cache-hit/download shortcuts below: those only ever
        # produce an installed prefix, never the $build tree with a
        # build.ninja this mode exists to guarantee.
        need git cmake
        [ -d "$src/.git" ] || die "$src missing; run fetch.sh llvm and apply.sh llvm first"
        llvm_cmake_configure "$src" "$build" "$prefix"
        echo "$build"; exit 0 ;;
esac

if [ -f "$prefix/.complete" ]; then
    log "LLVM cache hit: $prefix"
    echo "$prefix"
    exit 0
fi

if [ "${LLVM_NO_DOWNLOAD:-0}" != 1 ] && command -v curl >/dev/null; then
    log "trying $LLVM_CACHE_URL/$asset"
    mkdir -p "$CACHE/llvm"
    if curl -sSfL --retry 3 -o "$CACHE/llvm/$asset" "$LLVM_CACHE_URL/$asset" 2>/dev/null; then
        rm -rf "$prefix.tmp"; mkdir -p "$prefix.tmp"
        tar -xJf "$CACHE/llvm/$asset" -C "$prefix.tmp"
        rm -f "$CACHE/llvm/$asset"
        [ -f "$prefix.tmp/.complete" ] || die "downloaded $asset is incomplete"
        rm -rf "$prefix"; mv "$prefix.tmp" "$prefix"
        log "LLVM downloaded into $prefix"
        echo "$prefix"
        exit 0
    fi
    log "not in the LLVM cache release, building"
fi

need git cmake ninja
[ -d "$src/.git" ] || die "$src missing; run fetch.sh llvm and apply.sh llvm first"

# The work tree must hold exactly base + series; otherwise the key lies.
head_patches=$(git -C "$src" rev-list --count "$commit..mos" 2>/dev/null || echo x)
want=$(find "$series_dir" -maxdepth 1 -name '*.patch' | wc -l)
[ "$head_patches" = "$want" ] || die "llvm work tree is not base + ${series_dir#$ROOT/} ($head_patches vs $want commits); run apply.sh llvm"
git -C "$src" diff --quiet HEAD || die "llvm work tree has uncommitted changes"

log "configuring LLVM (key $key, targets $targets;$experimental, projects '${projects}')"
llvm_cmake_configure "$src" "$build" "$prefix"

log "building LLVM with $JOBS jobs (log: $WORK/llvm-build.log)"
keep_going=()
[ "${LLVM_KEEP_GOING:-0}" = 1 ] && keep_going=(-k 0)   # report every error at once (CI)
ninja -C "$build" -j "$JOBS" "${keep_going[@]}" install >"$WORK/llvm-build.log" 2>&1 \
    || { tail -60 "$WORK/llvm-build.log" >&2; die "LLVM build failed"; }

# FileCheck/count/not are real compiled tools test.sh tier 1 needs; llvm-lit
# itself is a script CMake writes at configure time, not a ninja target (a
# stray `ninja llvm-lit` fails with "unknown target"), so it is not built,
# only checked for. Non-fatal: test.sh already skips tier 1 if it's missing.
ninja -C "$build" -j "$JOBS" FileCheck count not >>"$WORK/llvm-build.log" 2>&1 \
    || warn "could not build FileCheck/count/not, tier 1 (lit) will be skipped"
[ -f "$build/bin/llvm-lit" ] || warn "$build/bin/llvm-lit not found, tier 1 (lit) will be skipped"
printf '%s\n' "commit=$commit" "patches=$patches_hash" "$config" > "$prefix/.complete"
log "LLVM installed in $prefix"
echo "$prefix"
