#!/usr/bin/env bash
# build-sdk.sh
#
# Provides the llvm-mos SDK (platform Clang drivers, C runtime, linker
# scripts, mos-sim) in $CACHE/sdk/<release>/llvm-mos and prints that path.
#
# The SDK is the official prebuilt release pinned by llvm_mos_sdk.release and
# checked against llvm_mos_sdk.sha256. Building it from source would need a
# full llvm-mos Clang of its own (the SDK tracks llvm-mos main), which is not
# the LLVM rustc is built against; see PLAN.md §6.
. "$(dirname "$0")/lib.sh"
need curl tar sha256sum

release=$(ver_get llvm_mos_sdk.release)
sha=$(ver_get llvm_mos_sdk.sha256)
[ -n "$release" ] || die "llvm_mos_sdk.release is not set in versions.toml"

case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) asset=llvm-mos-linux.tar.xz ;;
    Linux-aarch64) asset=llvm-mos-linux-arm64.tar.xz ;;
    Darwin-arm64) asset=llvm-mos-macos.tar.xz ;;
    *) die "no prebuilt llvm-mos SDK for $(uname -s)-$(uname -m)" ;;
esac

dest="$CACHE/sdk/$release"
if [ -x "$dest/llvm-mos/bin/mos-sim" ]; then
    log "SDK $release already installed"
    echo "$dest/llvm-mos"
    exit 0
fi

tarball="$CACHE/sdk/${asset%.tar.xz}-$release.tar.xz"
mkdir -p "$CACHE/sdk"
if [ ! -f "$tarball" ]; then
    log "downloading llvm-mos SDK $release ($asset)"
    curl -sSfL --retry 3 -o "$tarball.tmp" \
        "$LLVM_MOS_SDK_URL_RELEASES/download/$release/$asset"
    mv "$tarball.tmp" "$tarball"
fi
if [ -n "$sha" ]; then
    echo "$sha  $tarball" | sha256sum -c --quiet - || die "SDK checksum mismatch for $tarball"
else
    warn "llvm_mos_sdk.sha256 unset; got $(sha256sum "$tarball" | cut -d' ' -f1)"
fi

rm -rf "$dest.tmp"
mkdir -p "$dest.tmp"
tar -xJf "$tarball" -C "$dest.tmp"
[ -x "$dest.tmp/llvm-mos/bin/mos-sim" ] || die "unexpected SDK layout in $asset"
rm -rf "$dest"
mv "$dest.tmp" "$dest"
log "SDK $release installed in $dest/llvm-mos"
echo "$dest/llvm-mos"
