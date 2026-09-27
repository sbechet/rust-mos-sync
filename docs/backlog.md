# Backlog

Items found by reviewing the issues and pull requests of
[mrk-its/rust-mos](https://github.com/mrk-its/rust-mos) and its companion
repositories (2026-09-27), checked against Rust 1.98.1 and our patches.

## Already covered by the current patches

- `c_int`/`c_uint` are 16 bits through `cfg(target_arch = "mos")` in
  `core::ffi` (rust-mos regressed on this: rust-mos#35, mos-hardware#66).
- `memcmp` returning a 16-bit `int`: in 1.98 rustc derives the type from
  `c_int_width`, no arch list to patch.
- Small copies emitted as vector loads/stores that llvm-mos cannot legalize
  (rust-mos#25, fixed there by commit 81e665c): 1.98 no longer has
  `scalar_copy_llvm_type`; copies go through `memcpy`. Keep a regression test.
- Calling convention: we mirror llvm-mos Clang (`MOSABIInfo`) instead of
  rust-mos' "every aggregate indirect", which is better for C interop.
- No cargo fork: rust-std is prebuilt, `-Z build-std` is not needed.

## Actions

0. **Upstream MOS support to `rust-lang/cc-rs`.** Bootstrap unconditionally
   probes a C compiler for every configured target (even pure `no_std` ones,
   `src/bootstrap/src/utils/cc_detect.rs`), through the `cc` crate, which
   rejects any target triple whose architecture (first component) it does not
   recognize. `mos` is not recognized (checked against `cc-rs` `main`,
   2026-09-27; no open issue or PR). Discovered when `mos-sim-none` first went
   through `x build`: not something rust-mos hit, since it never had a
   built-in target sanity-checked by current bootstrap. Worked around for now
   by vendoring a patched `cc` 1.2.28 in `src/bootstrap/cc-mos-vendor` (patch
   0003), wired via `[patch.crates-io]`; drop it once a `mos` arch is
   upstreamed (one match arm in `src/target/parser.rs::parse_arch`, same as
   `avr`/`msp430`/`m68k`) and re-vendor whenever `src/bootstrap/Cargo.toml`'s
   `cc = "=X.Y.Z"` pin changes at an LLVM/Rust bump.

1. **More built-in platform targets.** The community uses `mos-<platform>-none`
   named after the SDK platform (vendor = platform, linker
   `mos-<platform>-clang`): most used `mos-c64-none` (done), `mos-sim-none`
   (done), then `mos-mega65-none`, `mos-atari8-dos-none`, `mos-nes-nrom-none`,
   `mos-cx16-none`. The CPU differs per platform (mega65: 45GS02, cx16: 65C02,
   pce: HuC6280), so each built-in target sets its `cpu`. Every target costs a
   rust-std build in CI (minutes); custom JSON targets remain possible for the
   rest but need nightly features, so built-ins are the stable-friendly path.
2. **compiler_builtins vs. the SDK runtime.** For no_std targets bootstrap enables
   `compiler-builtins-mem`, so the Rust `memcpy`/`memset`/`memcmp`, soft-float
   and integer helpers are linked (weak symbols). rust-mos cfg'd them out on MOS
   to use the SDK's hand-written 6502 versions. Measure the code size (tier 4),
   then consider not enabling `compiler-builtins-mem` and cfg-ing the `float` /
   `int` modules out for MOS if the SDK provides every symbol.
3. **Document the entry point**: `#![no_std]`, `#![no_main]`,
   `#[unsafe(no_mangle)] extern "C" fn main() -> c_int` (called by the SDK
   crt0); `#[start]` no longer exists. Put a C64 example in the README and the
   Docker image docs.
4. **`asm!` support** (`InlineAsmArch::Mos`): not requested by the community so
   far, but needed for interrupts and hardware access without C shims. Watch
   llvm-mos#84 (inline asm with `jsr`).
5. **LLVM codegen flags**: our list matches the current llvm-mos Clang defaults
   (`addMOSCodeGenArgs`); rust-mos also passed
   `--two-entry-phi-node-folding-threshold=0`, which current Clang no longer
   does. Re-check this list at every LLVM bump.

## Cosmetic

- Linking any MOS binary prints (to stderr, non-fatal):
  `ld.lld: ...libcompiler_builtins-*.rlib: archive member 'lib.rmeta'
  ('lib.rmeta-link') is neither ET_REL nor LLVM bitcode`. lld inspects every
  member of the `.rlib` archive under `-flto` and complains about the two
  that hold only Rust metadata, not object code or bitcode; harmless (the
  link still succeeds), just noisy. Silence if it turns out to bother users,
  otherwise leave it - not worth a patch on its own.
- `llvm-size`/`llvm-readelf` from the SDK refuse every `mos-sim` binary
  ("not recognized as a valid object file"), Rust or plain C alike (checked
  with a trivial `int main(void) { return 0; }` compiled by `mos-sim-clang`):
  the `sim` platform's link step produces a raw memory image, not an ELF, for
  `mos-sim` to load directly - the tools are simply the wrong ones for this
  platform's output, not a bug. `test.sh`'s size tier (§9 tier 4) now skips a
  program's measurement on such a failure instead of aborting the whole run.
  A real platform to size-check (`mos-c64-none`, an actual ELF) is still
  useful; add one once its `.cfg` and runtime story are worked out.

## Regression tests to add to tests/programs

Add them one at a time. An item known to fail upstream goes in as an expected
failure, with a link to the upstream issue, so it does not block the pipeline.

- float → int `as` casts (saturating `fptosi.sat`), gave wrong values
  (rust-mos#27, llvm-mos-sdk#299). **Fixed here**: on our newer LLVM this is a
  hard `unable to legalize instruction` at compile time rather than a silent
  wrong result — `G_FPTOSI_SAT`/`G_FPTOUI_SAT` had no action definition at
  all in the MOS legalizer. Hit building `compiler_builtins`'s libm
  (`rem_pio2_large`), so also unavoidable as soon as any float math is
  linked in. Fixed with `.lower()` (`patches/llvm`), which expands to the
  regular (non-saturating) libcall plus comparisons/selects MOS already
  legalizes. Regression test: `as` casts from f32/f64 to every int width,
  including out-of-range and NaN values (the rust-mos#27 report).
- three-way compare (`G_SCMP`/`G_UCMP`, not in the rust-mos-era backlog: a
  newer GlobalISel opcode `core`'s exact float formatting now uses,
  `flt2dec::strategy::dragon::format_exact`) had no action definition either,
  same "unable to legalize" failure, unconditionally hit formatting any
  float with `{}`. **Fixed here** with `.lower()` (`patches/llvm`), expanding
  to `G_ICMP` + `G_SELECT` like the existing `G_SMIN`/`G_SMAX` handling.
- `u128` arithmetic and division (rust-mos#29: `G_UDIV s128` failed to
  legalize; llvm-mos#236, #237). **Fixed here**: hit for real building `core`
  itself (`fmt::num::exp_u128`, i.e. `{}`-formatting a u128 — unconditionally
  compiled, no way to avoid it by not using u128). The MOS legalizer clamped
  G_SDIV/G_SREM/G_UDIV/G_UREM to a max of S64 before reaching the generic
  `.libcall()` action, so S128 fell through unhandled; widened to S128
  (`patches/llvm`, `MOSLegalizerInfo.cpp`) — the generic legalizer already
  resolves S128 to the `__udivti3`/`__divti3`/`__umodti3`/`__modti3` libcalls
  compiler_builtins provides. Regression test: format a large i128/u128.
- `f16`/`f128` in `core`/`compiler_builtins` (not in the rust-mos-era backlog —
  rustc now assumes `f16`/`f128` work everywhere unless denied per-target,
  a mechanism rust-mos's older Rust predates). **Fixed here**:
  `has_reliable_f16`/`has_reliable_f128`
  in `rustc_codegen_llvm/src/llvm_util.rs` now return false for MOS
  (`G_FCONSTANT half` does not legalize), so those routines are not compiled.
  `f128` excluded proactively, unverified. Revisit if/when the backend gains
  real support — this was a fast target-level opt-out, not a backend fix.
- `u64::checked_mul` (llvm-mos#235, hang on `smul.with.overflow.i64`).
- copies of small arrays and structs (rust-mos#25, vector legalization).
- the same program at opt-level 0, 1, 2, 3, "s" and "z" (rust-mos#28: debug build
  gave wrong output).
- `alloc` with a `GlobalAlloc` over the SDK `malloc`/`realloc`
  (llvm-mos-sdk#314: overlapping `realloc` blocks, fixed in recent SDKs).
- C interop: structs of 1-4 bytes and > 4 bytes passed and returned between
  Rust and C compiled by the SDK Clang (checks our calling convention).
- code-size benchmark: nested nop loop (rust-mos#32).
