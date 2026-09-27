#!/usr/bin/env bash
# build-llvm.sh [<channel>]
#
# Builds the patched LLVM ($WORK/llvm-project, branch `mos`) and installs it in
# $CACHE/llvm/<key>, where <key> hashes the Rust LLVM commit, the patch series
# and the build configuration (PLAN.md §3.4). A cache hit skips the build.
# Prints the install prefix on stdout.
#
# Environment:
#   LLVM_PROJECTS   default "clang;lld" (PLAN.md §6)
#   JOBS            compile jobs (default: nproc); LINK_JOBS default 1
. "$(dirname "$0")/lib.sh"
need git cmake ninja python3 sha256sum

channel="${1:-stable}"
src="$WORK/llvm-project"
build="$WORK/llvm-build"
commit=$(ver_get "rust.$channel.llvm_commit")
[ -d "$src/.git" ] || die "$src missing; run fetch.sh llvm and apply.sh llvm first"

# MOS is an experimental target in llvm-mos: it must go through
# LLVM_EXPERIMENTAL_TARGETS_TO_BUILD, not LLVM_TARGETS_TO_BUILD.
targets="X86"
case "$(uname -m)" in aarch64|arm64) targets="X86;AArch64" ;; esac
experimental="MOS"
projects="${LLVM_PROJECTS-clang;lld}"
LINK_JOBS="${LINK_JOBS:-1}"

# Everything that influences the produced binaries goes into the key.
config="targets=$targets experimental=$experimental projects=$projects host=$(host_triple)"
patches_hash=$(cat "$ROOT"/patches/llvm/*.patch 2>/dev/null | sha256sum | cut -c1-16)
key="$(printf '%s\n%s\n%s\n' "$commit" "$patches_hash" "$config" | sha256sum | cut -c1-16)"
prefix="$CACHE/llvm/$key"

if [ -f "$prefix/.complete" ]; then
    log "LLVM cache hit: $prefix"
    echo "$prefix"
    exit 0
fi

# The work tree must hold exactly base + series; otherwise the key lies.
head_patches=$(git -C "$src" rev-list --count "$commit..mos" 2>/dev/null || echo x)
want=$(find "$ROOT/patches/llvm" -maxdepth 1 -name '*.patch' | wc -l)
[ "$head_patches" = "$want" ] || die "llvm work tree is not base + patches/llvm ($head_patches vs $want commits); run apply.sh llvm"
git -C "$src" diff --quiet HEAD || die "llvm work tree has uncommitted changes"

cc=cc; cxx=c++; linker_flags=()
if command -v clang >/dev/null && command -v clang++ >/dev/null; then cc=clang; cxx=clang++; fi
command -v ld.lld >/dev/null && linker_flags=(-DLLVM_USE_LINKER=lld)
launcher=()
if command -v sccache >/dev/null; then launcher=(-DCMAKE_C_COMPILER_LAUNCHER=sccache -DCMAKE_CXX_COMPILER_LAUNCHER=sccache)
elif command -v ccache >/dev/null; then launcher=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache); fi

log "configuring LLVM (key $key, targets $targets;$experimental, projects '${projects}')"
cmake -S "$src/llvm" -B "$build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_C_COMPILER="$cc" -DCMAKE_CXX_COMPILER="$cxx" \
    "${linker_flags[@]}" "${launcher[@]}" \
    -DLLVM_TARGETS_TO_BUILD="$targets" \
    -DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD="$experimental" \
    -DLLVM_ENABLE_PROJECTS="$projects" \
    -DLLVM_BUILD_LLVM_DYLIB=ON -DLLVM_LINK_LLVM_DYLIB=ON \
    -DLLVM_INSTALL_UTILS=ON -DLLVM_INCLUDE_TESTS=ON \
    -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_ENABLE_ZLIB=ON -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_BINDINGS=OFF \
    -DLLVM_PARALLEL_COMPILE_JOBS="$JOBS" -DLLVM_PARALLEL_LINK_JOBS="$LINK_JOBS" \
    -DLLVM_VERSION_SUFFIX="-rust-mos" \
    >"$WORK/llvm-cmake.log" 2>&1 || { tail -40 "$WORK/llvm-cmake.log" >&2; die "cmake failed"; }

log "building LLVM with $JOBS jobs (log: $WORK/llvm-build.log)"
ninja -C "$build" -j "$JOBS" install >"$WORK/llvm-build.log" 2>&1 \
    || { tail -60 "$WORK/llvm-build.log" >&2; die "LLVM build failed"; }

# lit and its helpers are needed by test.sh tier 1 even from the cache.
ninja -C "$build" -j "$JOBS" FileCheck count not llvm-lit >>"$WORK/llvm-build.log" 2>&1
printf '%s\n' "commit=$commit" "patches=$patches_hash" "$config" > "$prefix/.complete"
log "LLVM installed in $prefix"
echo "$prefix"
