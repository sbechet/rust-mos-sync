# Git hosting and binary distribution

Status: **accepted in principle** (hosting on GitHub, decided by the maintainer on
2026-09-27); details to be applied once Phase 1 works (a toolchain built by the
scripts runs `tests/programs/hello` on `mos-sim`). Complements PLAN.md §7.5,
§10 and §11.

Two separate problems:

1. **Git**: where the recipe (patches, scripts, config, `versions.toml`) lives.
2. **Binaries**: how users, CI and a rebuilt machine get toolchains and
   intermediate builds without recompiling (LLVM ≈ 6–7 h and rustc ≈ 3–5 h on
   the maintainer's 2-core machine, roughly half that on a GitHub runner).

## 1. Git

### 1.1 What is versioned

| In git | Not in git |
|---|---|
| `patches/`, `scripts/`, `config/`, `targets/`, `tests/`, `ci/`, `docker/`, `.github/`, `versions.toml`, docs | `work/` (upstream checkouts, build trees), `cache/` (LLVM installs, SDK), any binary |

Upstream sources (rust-lang/rust, rust-lang/llvm-project, llvm-mos) are never
mirrored: they are fetched by `scripts/fetch.sh` at the commits pinned in
`versions.toml`. A commit of this repo + `versions.toml` fully identifies a
toolchain.

The LLVM patch is a single ~3 MB `git format-patch` file. Git stores it
compressed and later regenerations differ only in the changed hunks, so repo
growth stays small. No Git LFS.

### 1.2 Hosting

- Public repository `rust-mos-sync` on GitHub, under the maintainer's account or
  an organisation. Licence to be chosen (the patches derive from
  Apache-2.0 WITH LLVM-exception and MIT/Apache-2.0 code; the scripts can use
  MIT OR Apache-2.0 like Rust).
- Pushes from the maintainer's machine use a **deploy key** with write access,
  dedicated to this repository. CI uses the workflow's `GITHUB_TOKEN`.
- The `origin` remote is added once the repository exists; nothing is pushed
  before the maintainer confirms.

### 1.3 Forks and upstream

- Anyone can fork this repository and follow it like any GitHub project; the
  recipe is small and has no binary.
- **Patches, not forks** (PLAN.md §2) still holds for Rust and LLVM: updating to
  a new upstream means re-applying `patches/` on the new upstream commit, which
  is what makes the updates automatic.
- For convenience, the release workflow may push the patched trees as branches
  of GitHub forks (`<owner>/rust` branch `mos-1.98.1`, `<owner>/llvm-project`
  branch `mos-rustc-22.1`) so the code can be browsed and linked. These branches
  are **generated** (force-pushed from `patches/`), never edited by hand.

### 1.4 Branches and tags

- `main`: always buildable; protected once CI exists (Phase 3): changes land
  through pull requests with required checks. Until then the maintainer pushes
  directly.
- `sync/rust-<version>`, `sync/mos-<date>`, `bump/llvm-<NN.N>`: branches opened
  by the workflows (PLAN.md §7), deleted after merge.
- Release tags: `v<rust-version>-mos.<N>` (e.g. `v1.98.1-mos.1`) on the `main`
  commit that produced the published binaries. Beta: `v1.99.0-beta-mos.<N>`.

### 1.5 Commit history

Small commits `<area>: <summary>` (PLAN.md §13). The initial local history
(Phase 1) is kept as is: it documents how the first MOS patch was obtained.

## 2. Binaries

| Artefact | Who uses it | Where | Kept |
|---|---|---|---|
| **Toolchain** (rustc + libLLVM, cargo, rust-std host + MOS, rust-src) | users | GitHub release `v<version>-mos.<N>` | all releases (the last few stable/beta advertised) |
| **Docker image** (toolchain + llvm-mos SDK) | users, CI of MOS projects | `ghcr.io/<owner>/rust-mos` | all tags; `stable` / `beta` move |
| **LLVM install** (`cache/llvm/<key>`) | this repo's CI, rebuilt machines | assets of the release `llvm-cache` | keys referenced by `versions.toml` + the previous ones |
| **llvm-mos SDK** | users and CI | not re-hosted: official release pinned in `versions.toml` | — |

Sizes are to be measured on the first real build (estimate: toolchain
≈ 150–200 MB xz per host, LLVM install ≈ 80–120 MB, image ≈ 1 GB uncompressed).
GitHub release assets may be up to 2 GiB each; there is no practical total
quota for a public repository, so no aggressive rotation is needed.

### 2.1 Toolchain releases

Produced by `scripts/dist.sh` (packages `build-rust.sh`'s stage directory,
see `docs/backlog.md` on why not `x dist`) and published by
`.github/workflows/release.yml` (implemented 2026-09-30) with
`gh release create v<rust.stable.tag>-mos.<release.mos_revision>` for stable,
or `gh release upload beta --clobber` for the rolling beta pre-release:

```
rust-mos-stable-x86_64-unknown-linux-gnu.tar.xz
rust-mos-stable-x86_64-unknown-linux-gnu.tar.xz.sha256
install-stable.sh
```

(`release.json` with repo commit/rust tag/llvm commit/patch hashes/SDK
release was considered but not built - not needed for `install.sh` to work,
and versions.toml + the git tag/commit already say all of this; tracked in
`docs/backlog.md` if a machine-readable manifest turns out to be wanted
later.)

- One combined tarball per host rather than the separate `x.py dist`
  components: easier to install.
- `install-<channel>.sh`, rendered from `config/install.sh.in` (its
  `@SDK_RELEASE@`/`@SDK_SHA256@` filled in from `versions.toml` at release
  time, so it always matches the SDK that release was actually tested
  against). Runs locally, compiles nothing:
  1. resolve the release tag (`/releases/latest` for stable, literally
     `beta` for beta) and download+verify the tarball (sha256);
  2. download the pinned llvm-mos SDK release if missing (its linkers and
     `mos-sim` are needed);
  3. unpack under `~/.local/share/rust-mos/<tag>-<host>`;
  4. `rustup toolchain link mos-stable <dir>` (or `mos-beta`), if `rustup`
     is on `PATH` - otherwise just prints where the toolchain landed;
  5. print the `PATH` addition for the SDK `bin/`.
  Usage: `cargo +mos-stable build --release --target mos-c64-none`.
- MOS targets ship only `core`, `alloc` and `compiler_builtins` (PLAN.md §3.2).
- Only `x86_64-unknown-linux-gnu` so far, matching everything else built and
  tested this session. Later (Phase 7): additional hosts, rustup channel
  manifests served from the releases so that
  `RUSTUP_DIST_SERVER=… rustup toolchain install` works directly.

### 2.2 Docker image

`docker/Dockerfile`, built by the reusable `.github/workflows/docker-image.yml`
(factored out 2026-09-30 so `build.yml`'s manual `docker` job - still gated
behind the `build_docker` input, for ad hoc testing - and `release.yml`'s
automatic one share the exact same build+smoke-test+push steps instead of
duplicating them), pushed to `ghcr.io/<owner>/rust-mos`:

- base `debian:trixie-slim`;
- the rust-mos toolchain and the llvm-mos SDK both on `PATH` directly (no
  rustup inside the image — the toolchain tarball is already a complete,
  standalone `bin/`+`lib/`);
- one `CARGO_TARGET_<TRIPLE>_LINKER` env var per built-in MOS target, so a
  project needs no `.cargo/config.toml` of its own;
- tagged by `scripts/docker-tags.sh`: always the moving `<channel>`
  (`stable`/`beta`) and `sha-<commit>` (debugging); and, only when called
  from `release.yml`, the immutable version tags - stable
  `<X.Y.Z>-mos.<N>` plus the moving `<X.Y>`, beta
  `<X.Y.Z>-beta-mos.<commit7>` (a beta has no revision counter: it is the
  first 7 characters of the Rust beta commit). No `v` prefix, unlike the
  GitHub release tags (`v1.98.1-mos.1`). Labels carry the channel, Rust
  version, LLVM version/commit and SDK release. `linux/amd64` only for now,
  `linux/arm64` once an aarch64 toolchain exists.
- smoke-tested before every push: builds and runs `tests/programs/hello` on
  `mos-sim` inside the image, and builds it for `mos-c64-none` (link-only,
  nothing to run in CI).

Usage:

```sh
docker run --rm -v "$PWD":/src -w /src ghcr.io/<owner>/rust-mos:stable \
    cargo build --release --target mos-c64-none
# -> target/mos-c64-none/release/<name> (a .prg loadable in VICE or on a C64)
```

### 2.3 LLVM installs (not recompiling LLVM)

LLVM only changes with an LLVM bump or a MOS backend sync. Its cache key (Rust
LLVM commit + hash of `patches/llvm/` + configuration) is computed by
`build-llvm.sh`.

- After a successful build, the workflow uploads `cache/llvm/<key>` as
  `llvm-<key>-<host>.tar.xz` to the release `llvm-cache`
  (`gh release upload llvm-cache …`).
- On a local cache miss, `build-llvm.sh` first downloads
  `https://github.com/<owner>/rust-mos-sync/releases/download/llvm-cache/llvm-<key>-<host>.tar.xz`
  (plain HTTPS, no token), and only compiles when it is absent.
- Installs use `LLVM_LINK_LLVM_DYLIB`, so they are relocatable.
- Tier 1 (lit) needs the LLVM build tree: it runs in the job that builds LLVM;
  when LLVM comes from the cache, tier 1 reports `SKIP` (already the case in
  `test.sh`).

Result: a Rust-only update (the most frequent case) rebuilds only rustc, and a
new machine or runner never recompiles LLVM.

### 2.4 rustc builds

rustc cannot be reused across Rust versions. For the same version, the
published toolchain is the reference (re-running tests or the Docker build
downloads it), and `sccache` helps repeated builds after a failed step.

## 3. Open questions for the maintainer

1. GitHub account or organisation, and repository name (`rust-mos-sync`?).
2. Licence of the repository.
3. Hosts: x86_64 Linux first, then aarch64 Linux and aarch64 macOS (GitHub
   provides free runners for all three)?
4. Keep the maintainer's machine as an optional self-hosted runner, or GitHub
   runners only?
