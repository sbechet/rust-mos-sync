#!/usr/bin/env bash
# build-rust.sh [<channel>]
#
# Renders config/bootstrap.toml.in into $WORK/rust/bootstrap.toml, pointing
# llvm-config at the cached patched LLVM and the MOS targets at the SDK, then
# builds a toolchain: rustc, cargo, the host rust-std and the MOS rust-std
# components (core, alloc, compiler_builtins only).
# The toolchain ends up in $WORK/rust/build/<host>/stage$STAGE; prints it.
#
# Environment:
#   MOS_TARGETS  default: every mos-* target of the patched rustc
#   STAGE        default 2 (what x.py dist ships); 1 halves the build time
#                for local iteration.
. "$(dirname "$0")/lib.sh"
need python3

channel="${1:-stable}"
src="$WORK/rust"
[ -d "$src/.git" ] || die "$src missing; run fetch.sh rust and apply.sh rust first"
host=$(host_triple)
STAGE="${STAGE:-2}"

llvm=$("$ROOT/scripts/build-llvm.sh" "$channel")
sdk=$("$ROOT/scripts/build-sdk.sh")

# Every built-in MOS target defined by patches/rust.
if [ -z "${MOS_TARGETS:-}" ]; then
    MOS_TARGETS=$(sed -n 's/^ *("\(mos-[a-z0-9_-]*\)", .*/\1/p' \
        "$src/compiler/rustc_target/src/spec/mod.rs" | tr '\n' ' ')
fi
[ -n "${MOS_TARGETS// }" ] || die "no MOS target found in rustc_target"
log "MOS targets: $MOS_TARGETS"

rustc_channel=$channel
[ "$channel" = beta ] && rustc_channel=beta

python3 - "$ROOT/config/bootstrap.toml.in" "$src/bootstrap.toml" \
    "$host" "$rustc_channel" "$llvm/bin/llvm-config" "$sdk" "$JOBS" $MOS_TARGETS <<'PY'
import sys
tmpl, out, host, channel, llvm_config, sdk, jobs, *targets = sys.argv[1:]
text = open(tmpl).read()
for k, v in {"@HOST@": host, "@CHANNEL@": channel, "@LLVM_CONFIG@": llvm_config,
             "@SDK@": sdk, "@JOBS@": jobs,
             "@MOS_TARGETS@": ", ".join(f'"{t}"' for t in targets)}.items():
    text = text.replace(k, v)
for t in targets:
    vendor = t.split("-")[1]
    driver = "mos-clang" if vendor == "unknown" else f"mos-{vendor}-clang"
    text += (f'\n[target.{t}]\n'
             f'cc = "{sdk}/bin/mos-clang"\n'
             f'cxx = "{sdk}/bin/mos-clang++"\n'
             f'ar = "{sdk}/bin/llvm-ar"\n'
             f'ranlib = "{sdk}/bin/llvm-ranlib"\n'
             f'linker = "{sdk}/bin/{driver}"\n'
             f'no-std = true\n')
open(out, "w").write(text)
PY

export PATH="$sdk/bin:$PATH"
cd "$src"
# bootstrap's --target takes one comma-separated list, not a repeated flag
# (clap: "the argument '--target <TARGET>' cannot be used multiple times").
targets_args=(--target "$(echo "$MOS_TARGETS" | tr ' ' ',')")

log "building rustc + cargo (stage $STAGE) — log: $WORK/rust-build.log"
./x build --stage "$STAGE" -j "$JOBS" compiler/rustc library/std src/tools/cargo \
    >"$WORK/rust-build.log" 2>&1 || { tail -60 "$WORK/rust-build.log" >&2; die "rustc build failed"; }

log "building MOS core/alloc: $MOS_TARGETS"
./x build --stage "$STAGE" -j "$JOBS" library/alloc "${targets_args[@]}" \
    >>"$WORK/rust-build.log" 2>&1 || { tail -60 "$WORK/rust-build.log" >&2; die "MOS library build failed"; }

log "toolchain ready in $src/build/$host/stage$STAGE"
echo "$src/build/$host/stage$STAGE"
