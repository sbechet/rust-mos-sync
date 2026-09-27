# Git hosting and binary distribution

Status: **proposal**, to be applied once Phase 1 works (a toolchain built by the
scripts runs `tests/programs/hello` on `mos-sim`). Complements PLAN.md §7.5,
§10 and §11; PLAN.md will be updated to point here once accepted.

Two separate problems:

1. **Git**: where the recipe (patches, scripts, config, `versions.toml`) lives.
2. **Binaries**: how users, CI and a rebuilt machine get toolchains and
   intermediate builds without recompiling (LLVM ≈ 6–7 h and rustc ≈ 3–5 h on
   the current 2-core builder).

## 1. Git

### 1.1 What is versioned

| In git | Not in git |
|---|---|
| `patches/`, `scripts/`, `config/`, `targets/`, `tests/`, `ci/`, `.forgejo/`, `versions.toml`, docs | `work/` (upstream checkouts, build trees), `cache/` (LLVM installs, SDK), any binary |

Upstream sources (rust-lang/rust, rust-lang/llvm-project, llvm-mos) are never
mirrored: they are fetched by `scripts/fetch.sh` at the commits pinned in
`versions.toml`. A commit of this repo + `versions.toml` fully identifies a
toolchain.

The LLVM patch is a single ~3 MB `git format-patch` file. Git stores it
compressed and later regenerations differ only in the changed hunks, so repo
growth stays small. No Git LFS.

### 1.2 Hosting

- Repository `rust-mos-sync` on Codeberg, under the maintainer's account (or an
  organisation if others join later). Public, licence to be chosen (the patches
  are derived from Apache-2.0 WITH LLVM-exception / MIT+Apache-2.0 code; the
  scripts can use MIT OR Apache-2.0 like Rust).
- Push over SSH from the builder with a key **dedicated** to this repo (Codeberg
  deploy key with write access) rather than the maintainer's personal key.
- The `origin` remote is added once the repository exists; nothing is pushed
  before the maintainer confirms.

### 1.3 Branches and tags

- `main`: always buildable; changes land through pull requests once CI exists
  (Phase 3). Until then the maintainer pushes directly.
- `sync/rust-<version>`, `sync/mos-<date>`, `bump/llvm-<NN.N>`: branches opened
  by the workflows (PLAN.md §7), deleted after merge.
- Release tags: `v<rust-version>-mos.<N>` (e.g. `v1.98.1-mos.1`) on the `main`
  commit that produced the published binaries. Beta: `v1.99.0-beta-mos.<N>`.
  The tag, and the `release.json` published with the binaries (see 2.2), link the
  binaries to the exact recipe.

### 1.4 Commit history

Small commits `<area>: <summary>` (PLAN.md §13). The initial local history
(Phase 1) is kept as is: it documents how the first MOS patch was obtained.

## 2. Binaries

Three kinds of artefacts, with different audiences and lifetimes:

| Artefact | Who uses it | Size (xz, per host) | Kept |
|---|---|---|---|
| **Toolchain** (rustc + libLLVM, cargo, rust-std host + MOS, rust-src) | users | ≈ 150–200 MB, to measure | current stable + beta, plus the previous stable |
| **LLVM install** (`cache/llvm/<key>`) | builder / CI / rebuilds | ≈ 80–120 MB, to measure | keys referenced by `versions.toml` (stable + beta) |
| **llvm-mos SDK** | users and builder | 100 MB | not re-hosted: the official release pinned in `versions.toml` |

Sizes must be measured on the first real build and this table updated.

### 2.1 Storage and Codeberg quota

Codeberg allows **1.5 GiB of packages + LFS + release attachments** per user
before a resource request is needed (750 MiB for git). With the sizes above:

- 3 toolchains × 1 host ≈ 0.6 GB, plus 2 LLVM installs ≈ 0.2 GB: this fits for **one
  host (x86_64 Linux)**, but only with rotation.
- As soon as a second host (aarch64 Linux, macOS) is added, the limit is
  exceeded. At that point, either submit a request to
  `codeberg.org/Codeberg-e.V./requests` (preferred: explain the project and the
  rotation), or move the storage to another host (see 2.5).

Rotation is therefore part of the design from the start: `scripts/forgejo.sh
prune` deletes releases and packages that are no longer kept (table above).

### 2.2 Toolchain releases (users)

Produced by `scripts/dist.sh` (`x.py dist`) and published by `release.yml` as a
**Codeberg release** attached to the tag `v<version>-mos.<N>`:

```
rust-mos-1.98.1-mos.1-x86_64-unknown-linux-gnu.tar.xz   # combined toolchain
rust-mos-1.98.1-mos.1-x86_64-unknown-linux-gnu.tar.xz.sha256
release.json      # repo commit, rust tag, llvm commit, patch hashes, SDK release
install.sh
```

- One combined tarball per host instead of the separate `x.py dist`
  components: easier to install, and a single file to rotate.
- `install.sh` (runs locally, no build):
  1. download and verify the tarball (sha256);
  2. download the pinned llvm-mos SDK release if missing (its linkers and
     `mos-sim` are needed);
  3. unpack under `~/.local/share/rust-mos/<version>`;
  4. `rustup toolchain link mos-stable <dir>` (or `mos-beta`);
  5. print the `PATH` addition for the SDK `bin/`.
  Usage: `cargo +mos-stable build --release --target mos-c64-none`.
- The toolchain contains no `std` for MOS targets, only `core`, `alloc` and
  `compiler_builtins` (PLAN.md §3.2).
- Later (PLAN.md §7.5 step 4, Phase 7): rustup channel manifests so that
  `RUSTUP_DIST_SERVER=… rustup toolchain install` works directly.

### 2.3 LLVM installs (builder, CI, disaster recovery)

The expensive part is LLVM, and it only changes with an LLVM bump or a MOS
backend sync. Its cache key (Rust LLVM commit + hash of `patches/llvm/` +
configuration) is already computed by `build-llvm.sh`.

- After a successful build, `build-llvm.sh` (or the workflow) uploads
  `cache/llvm/<key>` as a tarball to the **Codeberg generic package registry**:
  `packages/generic/rust-mos-llvm/<key>/llvm-<key>-<host>.tar.xz`.
- On a local cache miss, `build-llvm.sh` first tries to download that package
  (plain HTTPS, no API token needed for a public repo), and only compiles when it
  is absent.
- The installs are built with `LLVM_LINK_LLVM_DYLIB`, so they are relocatable:
  unpacking them to another path works.
- The lit tests (tier 1) need the LLVM build tree, not the install; when LLVM
  comes from the package, tier 1 was already run when the package was produced
  and is reported as `SKIP` (already the case in `test.sh`).

Result: a Rust-only update (the most frequent case) rebuilds only rustc
(≈ 3–5 h here), and a new or reinstalled builder does not recompile LLVM.

### 2.4 rustc builds

rustc cannot be reused from one Rust version to the next. To avoid rebuilding
the *same* version:

- the published toolchain (2.2) is the reference: re-running tests or dist for a
  version already released downloads it instead of rebuilding;
- `sccache` on the builder (PLAN.md §11) speeds up the C/C++ parts and repeated
  builds of the same version after a failed step.

### 2.5 Fallback if Codeberg storage is not enough

Keep the same URL layout on another static HTTPS host (the maintainer's own
server, or S3-compatible object storage behind a domain name). The scripts take
the base URLs from variables in `scripts/lib.sh` (`DIST_BASE_URL`,
`LLVM_CACHE_URL`), so switching hosts only changes configuration, not code.

## 3. Open questions for the maintainer

1. Codeberg account or organisation name, and repository name (`rust-mos-sync`?).
2. Licence of the repository.
3. Initial hosts to publish: x86_64 Linux only for now (the builder), or aarch64 /
   macOS later?
4. The builder has 2 cores: should it also be the Forgejo runner (Phase 3)? A
   Rust-only sync would take ≈ 4–6 h, which is acceptable for a daily cron but
   not for fast iteration.
5. Is it acceptable to request more storage from Codeberg, or should a
   personal server be used for the binaries?
