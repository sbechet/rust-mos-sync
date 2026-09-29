#!/usr/bin/env bash
# dist.sh [<channel>]
#
# Packages the toolchain built by build-rust.sh (rustc, the MOS-linked cargo,
# host rust-std, MOS rust-std for every target) as a single tarball, ready to
# extract straight into a `rustup toolchain link` directory.
# Prints the tarball path.
#
# This packages build-rust.sh's raw stage directory rather than a proper
# `x dist`/`x install` output: x dist hard-codes stage 2 for some components
# (e.g. rustc-dev), which would give up the STAGE=1 speed this pipeline
# relies on in CI, and needs more validation for our no_std MOS targets than
# is safe to take on casually. Tracked in docs/backlog.md as a real
# migration to attempt later; this script is the seam where that would land
# without touching build.yml again.
. "$(dirname "$0")/lib.sh"
need tar

channel="${1:-stable}"
host=$(host_triple)
STAGE="${STAGE:-2}"
stage_dir="$WORK/rust/build/$host/stage$STAGE"
tools_bin="$WORK/rust/build/$host/stage$STAGE-tools-bin"

[ -x "$stage_dir/bin/rustc" ] || die "$stage_dir/bin/rustc missing; run build-rust.sh first"

# cargo is built into a separate "tools" output directory, not the stage
# sysroot itself; drop it into bin/ next to rustc for a self-contained tree.
if [ -x "$tools_bin/cargo" ] && [ ! -e "$stage_dir/bin/cargo" ]; then
    cp "$tools_bin/cargo" "$stage_dir/bin/cargo"
fi
[ -x "$stage_dir/bin/cargo" ] || die "cargo missing from $stage_dir/bin and $tools_bin"

out="$WORK/rust-mos-$channel-$host.tar.xz"
tar -C "$stage_dir" -cJf "$out" .
log "toolchain packaged: $out ($(du -h "$out" | cut -f1))"
echo "$out"
