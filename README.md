# rust-mos-sync

A Rust toolchain for the MOS 6502 family (Commodore 64, NES, Atari, …), built on
the [llvm-mos](https://github.com/llvm-mos/llvm-mos) backend and kept in sync
with every Rust stable release (and a preview for each beta).

This repository contains no fork: it stores **patches** on top of
`rust-lang/rust` and Rust's `rust-lang/llvm-project` branch, the scripts that
apply and build them, and the tests. `versions.toml` pins the exact upstream
commits of the current toolchain.

MOS targets are `#![no_std]`: they ship `core` and `alloc`, never `std`.

Status: bootstrap in progress (Phase 1 of [PLAN.md](PLAN.md)). Binary releases
and a ready-to-use Docker image are planned, see
[docs/git-and-distribution.md](docs/git-and-distribution.md).

## Building locally

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
