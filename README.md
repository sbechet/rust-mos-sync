# rust-mos-sync

A Rust toolchain for the MOS 6502 family (Commodore 64, NES, Atari, …), built on
the [llvm-mos](https://github.com/llvm-mos/llvm-mos) backend and kept in sync
with every Rust stable release (and a preview for each beta).

This repository contains no fork: it stores **patches** on top of
`rust-lang/rust` and Rust's `rust-lang/llvm-project` branch, the scripts that
apply and build them, and the tests. `versions.toml` pins the exact upstream
commits of the current toolchain.

MOS targets are `#![no_std]`: they ship `core` and `alloc`, never `std`.

Status: Phases 1-2 of [PLAN.md](PLAN.md) done (a built toolchain runs
`tests/programs/hello` on `mos-sim`, with vanilla `cargo`); Phase 3 (CI syncs
and releases) in progress - the Docker image below is already built and
published. See [docs/git-and-distribution.md](docs/git-and-distribution.md)
for the full binary distribution plan.

## Using the Docker image

The quickest way to compile a MOS crate needs nothing installed locally but
Docker. The image bundles the Rust toolchain (rustc, cargo, and `core`/`alloc`
for every built-in MOS target - no `std`) and the llvm-mos SDK (the linker for
each target, the C runtime, the `mos-sim` simulator) on `PATH`; nothing gets
compiled when the image itself is built, and nothing needs to be installed to
use it.

```
ghcr.io/sbechet/rust-mos:stable    # tracks rust.stable in versions.toml
ghcr.io/sbechet/rust-mos:beta      # tracks rust.beta
```

### Example: building a crate `foo` for the Commodore 64

```sh
cargo new foo
cd foo
```

Replace `src/main.rs` with a `#![no_std]`, `#![no_main]` program with a
C-style entry point (there is no `std::env`/`println!`, and no `#[start]`
either - MOS is a bare-metal target, `main` is called directly by the SDK's
C runtime):

```rust
// src/main.rs
#![no_std]
#![no_main]

use core::panic::PanicInfo;

#[unsafe(no_mangle)]
pub extern "C" fn main() -> core::ffi::c_int {
    // ... your program ...
    0
}

#[panic_handler]
fn panic(_: &PanicInfo) -> ! {
    loop {}
}
```

Add this to `Cargo.toml` - MOS has no stack unwinding:

```toml
[profile.release]
panic = "abort"
```

Then build it with the image. No `.cargo/config.toml` is needed: the image
already sets the linker for every built-in target as a `CARGO_TARGET_*_LINKER`
environment variable.

```sh
docker run --rm -v "$PWD":/src -w /src ghcr.io/sbechet/rust-mos:stable \
    cargo build --release --target mos-c64-none
```

`target/mos-c64-none/release/foo` is a real Commodore 64 `.prg` file (a `01
08` load-address header, then the standard llvm-mos `SYS` BASIC stub, then
your code) - load it straight into [VICE](https://vice-emu.sourceforge.io/)
or onto real hardware.

### Running it without an emulator: `mos-sim-none`

`mos-sim-none` targets llvm-mos's own simulator, which the image can also
*run* (not just build for) - useful to check a program actually works before
reaching for VICE or hardware:

```sh
docker run --rm -v "$PWD":/src -w /src ghcr.io/sbechet/rust-mos:stable \
    sh -c 'cargo build --release --target mos-sim-none &&
           mos-sim target/mos-sim-none/release/foo'
```

`tests/programs/hello` in this repository is a minimal, known-working example
of exactly this (`putchar`-based output, no platform needed) if you want a
reference to start from.

### Other built-in targets

`mos-unknown-none` (no specific platform - your own linker script, for a
fully self-contained program) is also built in. To list every target the
image currently supports:

```sh
docker run --rm ghcr.io/sbechet/rust-mos:stable rustc --print target-list | grep ^mos-
```

## Building the toolchain from source

```sh
scripts/fetch.sh llvm && scripts/apply.sh llvm base-stable
scripts/fetch.sh rust && scripts/apply.sh rust base-stable
STAGE=1 scripts/build-rust.sh     # builds LLVM and fetches the llvm-mos SDK first
scripts/test.sh
```

## Licence

Same licences as the upstream projects:

- `patches/llvm/`: Apache License v2.0 with LLVM Exceptions, like LLVM and
  llvm-mos (see [patches/llvm/LICENSE.TXT](patches/llvm/LICENSE.TXT)).
- Everything else, including `patches/rust/`: MIT or Apache License 2.0, at
  your option, like Rust (see [LICENSE-MIT](LICENSE-MIT) and
  [LICENSE-APACHE](LICENSE-APACHE)).

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in this repository shall be licensed as above, without any
additional terms or conditions.
