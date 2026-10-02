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
- Host `rust-std` (`libstd-*.rlib`) surviving in the packaged toolchain
  (needed for a downstream crate's `build.rs` or any other host binary;
  reported by a sibling MOS project, c64-nokernal, hitting `E0463: can't find
  crate for std`). Root cause: `src/bootstrap/src/core/build_steps/compile.rs`
  `Sysroot::run` unconditionally does `fs::remove_dir_all(&sysroot)` on the
  *entire* `stage$STAGE` directory every time it re-assembles a compiler
  ("Removing sysroot ... to avoid caching bugs") - the second `./x build`
  invocation (MOS-only targets) wipes what the first (host) just installed.
  `build-rust.sh` now snapshots the host sysroot right after the host build
  and restores it over the final directory after the MOS build, rather than
  trusting the stage directory to accumulate across multiple invocations. A
  real fix (using `x dist`/`x install`, bootstrap's own sanctioned mechanism
  for producing a stable component bundle, instead of packaging its internal
  working directory directly) is a separate, larger follow-up: `x dist`
  hard-codes stage 2 for some components (e.g. `rustc-dev`), which would give
  up the STAGE=1 speed this pipeline relies on in CI, and needs real
  validation for no_std MOS targets before it can replace the snapshot/
  restore approach `scripts/dist.sh` uses now.

## Actions

-1. **Beta needs an LLVM bump before it can build at all. RESOLVED 2026-10-02**
    (`patches/llvm/23.1/`, PR #7; beta and stable both ship on it now; the
    original analysis follows, kept for the record). Found by the
    first real `sync-rust.yml` dispatch (channel=beta, 2026-09-30):
    `patches/llvm/` was extracted for `rustc/22.1-2026-05-19` only (stable's
    branch at the time); beta has been on `rustc/23.1-2026-07-22` since this
    repository's very first `versions.toml` - not upstream drift during this
    project, just the normal state PLAN.md §3.5 describes ("LLVM bumps
    appear on beta 6-12 weeks before stable"). The build failed at
    `apply.sh llvm` (`git am -3`: "not our ref", the promisor remote
    couldn't lazily fetch a blob needed for the 3-way merge) - expected,
    since the patch was never calibrated for 23.1.
    `detect.sh` originally compared a channel's new candidate against that
    *same channel's own previously recorded* `llvm_branch`, which is wrong:
    beta's recorded branch was already 23.1, so "unchanged" looked like "no
    bump needed" and would have retried (and failed) the build daily via
    `watch.yml`. Fixed by comparing against a new authoritative
    `llvm_mos.patched_branch` field (the branch the patches actually target)
    instead - beta now correctly classifies as `llvm-bump`, not `sync-rust`.
    Real fix is Phase 6 (`llvm-bump.yml`, `scripts/llvm-bump.sh`, 2026-10-01):
    extract a MOS patch against 23.1 into `patches/llvm/23.1/` (patches are
    now per LLVM version and `patched_branch` no longer exists). Tracking issue:
    https://github.com/sbechet/rust-mos-sync/issues/1 (opened by the failed
    run, before this fix - can be closed/left as a Phase 6 reminder).
    Phase 3's sync-rust.yml mechanics (detection, branch, versions.toml bump,
    conditional steps, failure issue) all worked correctly end to end in
    this same run; only stable's actual success path (build+test+PR) still
    needs a real run to be confirmed, which needs an actual new stable tag.

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

1. **More built-in platform targets. Done (2026-09-30).** Every
   `mos-<platform>-clang` driver llvm-mos-sdk's README lists now has a
   matching built-in `mos-<platform>-none` target (vendor = platform,
   linker `mos-<platform>-clang`): patch 0005 added `mos-nes-nrom-none` and
   `mos-atari8-dos-none` first (both plain `mos6502` like `mos-c64-none`/
   `mos-sim-none`), then patch 0006 added the remaining 32 - Apple II (`mos-a2-none`: patch 0009 renamed it from
   `mos-apple2-none`, since bootstrap treats any target name containing
   "apple" as an Apple platform; hyphenated platform names also needed the
   cc parser fix, patch 0007, and underscores in `target_vendor`, 0008),
   Atari 2600 (4K/3E)/5200/8-bit (DOS/std/MegaCart/XEGS cartridges), Atari
   Lynx (BLL), Ben Eater's breadboard, Commander X16, Commodore 128/PET/
   VIC-20, CP/M-65, Dodo, GEOS, MEGA65, every NES mapper (Action53/CNROM/
   GTROM/MMC1/MMC3/UNROM/UNROM-512) plus FDS, Ohio Scientific, Neo6502,
   RP6502, PC Engine (+CD), RPC/8e, Watara Supervision.
   `base::mos::target()` now takes an explicit `cpu`, matched to each
   platform's own `clang.cfg` default (inherited from its SDK `PARENT`
   platform when it sets none itself - checked against the llvm-mos-sdk
   checkout, not guessed): plain `mos6502` for most, `mos6502x` for the
   Atari 2600 family (undocumented opcodes only), `mosw65c02`/`mos65c02`
   for the WDC-65C02-based platforms (cx16, eater, neo6502, rp6502 /
   lynx-bll, supervision), `moshuc6280` for the PC Engine, `mos45gs02` for
   MEGA65, `mos65el02` for RPC/8e. `build-rust.sh`/`test.sh` pick up every
   new target automatically (they discover `mos-*` targets from
   `rustc_target/src/spec/mod.rs` rather than a hardcoded list), and
   `docker-image.yml`'s smoke test now link-builds every target except
   `mos-unknown-none` (no real platform to link against) and `mos-sim-none`
   (already build+run tested). Not ported: the SDK's shared, non-leaf
   "-common"/base configs (`common`, `atari8-common`, `atari2600-common`,
   `pce-common`, `commodore`, `lynx`) have no `mos-<name>-clang` driver of
   their own - only their COMPLETE children do.
   Every target costs a rust-std build in CI (minutes) - with 37 MOS
   targets now built-in, watch the `rust` job's wall-clock on the next real
   CI run; custom JSON targets remain possible for anything llvm-mos adds
   later but need nightly features, so built-ins stay the stable-friendly
   path.
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
  with a trivial `int main(void) { return 0; }` compiled by `mos-sim-clang`).
  Confirmed with `od`: the file has no ELF magic at all (`00 02 24 00 a9 f0
  85 00 ...` - straight 6502 opcodes, `a9 f0` = `LDA #$F0`, behind what looks
  like a small load-address/length header). The `sim` platform's link step
  emits a raw memory image for `mos-sim` to load directly, not an ELF - the
  tools are simply the wrong ones for this platform's output, nothing to
  patch in `llvm-size`, and no LLVM/rustc gap either. `test.sh`'s size tier
  (§9 tier 4) now falls back to the size of the file on disk in that case,
  which for this format *is* the direct code+data measurement (header
  overhead: a few bytes). A platform that links a real ELF (`mos-c64-none`,
  once its `.cfg` and runtime story are worked out) would let the section
  breakdown (`.text`/`.rodata`/`.data` separately) work too.

## Notes from other in-progress MOS projects on this machine

- **Custom C64 linker scripts**: the SDK's `mos-c64-clang` only omits its own
  default `-Tlink.ld` when it sees a `-T` on the *clang* command line, not a
  linker-only `-Wl,-T,...` (`MOSToolChain::addClangTargetOptions` /
  `mos::Linker::ConstructJob`) — the latter leaves both scripts active
  ("region 'ram' already defined"). From Rust:
  `rustflags = ["-C", "link-arg=-T", "-C", "link-arg=<script>.ld"]`. Relevant
  to any program that reclaims part of `link.ld`'s default `$0801-$CFFF`
  (e.g. hi-mem $A000-$BFFF) for itself. Worth a line in the README/docs once
  we document custom platforms.
- **`core::fmt` code size**: a couple of `write!`s with `{:02}`/`{:?}` cost
  about 2 KB on a C64-budget (`$0801-$9FFF`) program — worth watching in tier
  4 once `tests/programs` exercises formatting (none do yet; `hello` only
  calls `putchar` directly).

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
