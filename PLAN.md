# rust-mos-sync — Automation Plan

This document is written for **Claude Code**. It describes the goal, the architecture and the implementation phases of `rust-mos-sync`, a project that keeps a Rust toolchain for the MOS 6502 family permanently in sync with **Rust stable**, using the **llvm-mos** backend.

The project is hosted on **GitHub**. CI uses **GitHub Actions** on GitHub-hosted runners (a self-hosted runner can be added later, see §11). Binaries are published as GitHub releases and container images on `ghcr.io` (see `docs/git-and-distribution.md`). The design stays *patches, not forks* (§2): GitHub forks of this repository are welcome, and patched upstream branches may be published for browsing, but they are always regenerated from `patches/`.

When something in this plan is ambiguous or conflicts with reality (e.g. an upstream layout changed), stop and ask the maintainer rather than guessing.

---

## 1. Context

- **llvm-mos** (`github.com/llvm-mos/llvm-mos`) is a fork of LLVM adding a MOS 65xx backend. It tracks upstream LLVM `main` continuously.
- **llvm-mos-sdk** (`github.com/llvm-mos/llvm-mos-sdk`) provides the C runtime, linker scripts, platform targets and the `mos-sim` simulator.
- **rust-mos** (`github.com/mrk-its/rust-mos`) was a fork of `rust-lang/rust` targeting MOS. It is now far behind Rust stable.
- **Rust** pins its LLVM via the `src/llvm-project` submodule, pointing at a branch of `rust-lang/llvm-project` named like `rustc/<llvm-major>.<minor>-<date>`.

**Root cause of rust-mos falling behind:** llvm-mos tracks LLVM `main`, while Rust stable uses an older, pinned LLVM. Building rustc against llvm-mos breaks `compiler/rustc_llvm` (the C++ wrapper) whenever the LLVM C++ API diverges.

## 2. Goals and non-goals

**Goals**

- Produce a MOS-capable Rust toolchain (rustc, cargo, and the `rust-std` distribution component for MOS targets — see §3.2) for **every Rust stable release**, and a preview for every beta.
- Fully automated pipeline; human involvement limited to optional approval.
- Everything reproducible locally with the same scripts the CI runs.
- Keep the patch sets as small as possible.

**Non-goals**

- No long-lived fork of `rust-lang/rust` or `rust-lang/cargo`. This repo stores **patches**, not forks.
- No `std` for MOS: these machines have no OS (no files, threads, network, clock). All MOS code is `#![no_std]` and uses only `core` and, with an allocator, `alloc`. Do not attempt a stub/"unsupported" `std` either.
- No upstreaming work in this repo (tracked separately).

## 3. Key design decisions

1. **Invert the LLVM fork direction.** Do not build rustc against llvm-mos `main`. Instead build an LLVM = *Rust's LLVM branch* + *the MOS backend patch*. The MOS patch is extracted from the llvm-mos merge commit whose upstream LLVM version is closest to Rust's branch, which keeps the diff essentially limited to MOS additions.
2. **Built-in MOS targets in rustc** (patch `compiler/rustc_target/src/spec/`) rather than JSON custom targets, so that `x.py dist` can ship a prebuilt `rust-std` component for MOS targets and users on stable do not need `-Z build-std`. If this proves too invasive, fall back to JSON targets + documented `RUSTC_BOOTSTRAP=1 -Z build-std=core,alloc`. Ask before switching.
   **Naming note:** `rust-std` is the name of the rustup/dist *component* holding the precompiled libraries for a target. For MOS targets it must contain **only `core`, `alloc` and `compiler_builtins` — never `std`** (same as existing `no_std` targets such as `thumbv6m-none-eabi`). Configure the targets and bootstrap accordingly.
3. **No cargo patch.** A vanilla cargo should work. The historical cargo fork only existed to force a patched `compiler-builtins`, which is believed to be no longer necessary. Verify in Phase 1; if a patch turns out to be needed, add `patches/cargo/` and report why.
4. **LLVM build is cached by content hash** (Rust LLVM commit + hash of `patches/llvm/`). Rust-only updates must reuse the cached LLVM.
5. **Beta is tracked, not just stable.** LLVM bumps appear on beta 6–12 weeks before stable; the pipeline must prepare them in advance.

## 4. Repository layout

```
rust-mos-sync/
├── PLAN.md                  # this file
├── CLAUDE.md                # short conventions + pointer to PLAN.md
├── versions.toml            # single source of truth for current state
├── patches/
│   ├── llvm/                # git format-patch series on top of rust-lang/llvm-project
│   └── rust/                # git format-patch series on top of rust-lang/rust tag
├── targets/                 # target definitions (source for rustc spec patch, or JSON fallback)
├── config/
│   └── bootstrap.toml.in    # template for rust's bootstrap config (config.toml on old versions)
├── tests/
│   ├── programs/            # small no_std Rust programs + expected mos-sim output
│   └── size-baseline.json   # code size baseline per test program
├── scripts/
│   ├── lib.sh               # shared helpers (logging, versions.toml read/write)
│   ├── fetch.sh             # clone/fetch upstream sources into work/
│   ├── apply.sh             # apply patch series; exit 2 on conflict
│   ├── build-llvm.sh
│   ├── build-sdk.sh
│   ├── build-rust.sh
│   ├── test.sh
│   ├── dist.sh
│   ├── regen-patches.sh     # re-export patch series from work trees
│   ├── detect.sh            # compare upstream state with versions.toml
│   └── github.sh            # PR / issue / release helpers via the `gh` CLI
├── ci/
│   └── claude/              # prompts used by CI for Claude Code
├── docker/                  # Dockerfile of the ready-to-use MOS toolchain image
└── .github/
    └── workflows/
        ├── watch.yml
        ├── sync-rust.yml
        ├── sync-mos-backend.yml
        ├── llvm-bump.yml
        └── release.yml
```

`work/` (upstream checkouts, build dirs) and `cache/` are git-ignored.

## 5. `versions.toml` schema

```toml
[rust.stable]
tag = "1.xx.y"                # rust-lang/rust tag
llvm_branch = "rustc/NN.N-YYYY-MM-DD"
llvm_commit = "<sha>"         # commit of src/llvm-project at that tag

[rust.beta]
tag = "1.xx.0-beta.N"
llvm_branch = "..."
llvm_commit = "..."

[llvm_mos]
base_merge = "<sha>"          # llvm-mos merge commit used to extract the MOS patch
last_synced = "<sha>"         # last llvm-mos commit whose MOS-only changes were cherry-picked
deferred = ["<sha>", ...]     # MOS commits that failed to apply; retried at next LLVM bump

[llvm_mos_sdk]
commit = "<sha>"

[release]
mos_revision = 1              # N in 1.xx.y-mos.N; reset to 1 on new Rust tag
```

All scripts read and write this file through helpers in `scripts/lib.sh`. Workflows only change it via commits in pull requests.

## 6. Script contracts

Every script must:

- be POSIX `sh` or `bash` with `set -euo pipefail`;
- be runnable locally with the same result as in CI;
- be idempotent;
- use exit codes: `0` success, `1` error, `2` patch conflict (so CI can hand over to Claude Code), `3` test failure.

Specifics:

- `fetch.sh <component>`: shallow where possible; never re-clone LLVM if `work/` already has the objects.
- `apply.sh <llvm|rust> <base-ref>`: creates a fresh branch from `<base-ref>` and runs `git am -3`. On conflict, leaves the tree in the conflicted state and exits `2`.
- `build-llvm.sh`: computes the cache key, restores from cache if present, otherwise builds with `LLVM_TARGETS_TO_BUILD="MOS;X86"` (add `AArch64` on arm64 hosts), `LLVM_ENABLE_PROJECTS="clang;lld"`, `LLVM_BUILD_LLVM_DYLIB=ON`, `LLVM_LINK_LLVM_DYLIB=ON`, utils installed, then stores in cache.
- `build-rust.sh`: renders `bootstrap.toml` from the template pointing `llvm-config` at the cached LLVM, sets `rust.description = "mos"` (or equivalent) and builds rustc, cargo and the host `rust-std` component, plus the MOS `rust-std` components (`core`, `alloc`, `compiler_builtins` only).
- `test.sh`: runs the test tiers of §9; writes a JUnit-style or plain summary to `work/test-report.txt`.
- `regen-patches.sh <llvm|rust>`: regenerates the series with `git format-patch --no-numbered --zero-commit --no-signature` so diffs between regenerations stay minimal.

## 7. Workflows (GitHub Actions)

Workflow files live in `.github/workflows/`. Prefer plain `run:` steps over third-party actions (only official `actions/*` ones). Heavy jobs run on GitHub-hosted `ubuntu-24.04` runners (4 vCPU, 16 GB RAM, ~14 GB free disk, 6 h per job): each workflow first frees disk space, and the build is split into jobs (LLVM, rustc, dist) that pass the LLVM install through the LLVM cache (§11) so no job exceeds 6 h.

### 7.1 `watch.yml` — detection (cron, daily)

1. Run `scripts/detect.sh`, which uses `git ls-remote` against `rust-lang/rust` for tags and the `src/llvm-project` submodule commit of the latest stable and beta tags, and against `llvm-mos/llvm-mos` and `llvm-mos-sdk` for new commits.
2. Depending on the diff with `versions.toml`, dispatch:
   - new Rust tag, same LLVM branch → `sync-rust.yml`
   - new Rust tag (usually beta) with a new LLVM branch → `llvm-bump.yml`
   - new llvm-mos commits touching `llvm/lib/Target/MOS` or `llvm/test/CodeGen/MOS` → `sync-mos-backend.yml`
3. Never run two sync workflows concurrently on the same channel (use a concurrency group).

### 7.2 `sync-rust.yml`

1. Fetch the new Rust tag; `apply.sh rust <tag>`.
2. On exit `2`, run Claude Code (§8) with `ci/claude/resolve-rust.md`.
3. Build LLVM (cache hit expected), SDK, Rust; run tests.
4. Update `versions.toml`, regenerate patches, open a PR with the test summary.

### 7.3 `sync-mos-backend.yml`

1. List new llvm-mos commits since `last_synced`, filtered on MOS-only paths.
2. Cherry-pick each onto the current LLVM work branch. Any commit that does not apply cleanly or breaks the MOS lit tests goes into `deferred` — do **not** involve Claude Code here, do not block.
3. Rebuild LLVM, run tests, regenerate `patches/llvm/`, open a PR.

### 7.4 `llvm-bump.yml`

1. Resolve the new `rustc/...` branch and its upstream LLVM version.
2. Find in llvm-mos history the upstream merge commit closest to (not newer than, if possible) that version. Record it as `base_merge`.
3. Extract the MOS patch as the diff between that merge commit and its upstream parent, restricted to MOS-relevant changes; list any file touched outside `llvm/lib/Target/MOS`, `llvm/test/*/MOS`, `clang/`, `lld/` in the PR description.
4. Apply onto the Rust LLVM branch; on conflict, Claude Code with `ci/claude/resolve-llvm.md`.
5. Retry `deferred` commits; keep those still failing.
6. Full build and full test suite. Open a PR labelled `llvm-bump` which **requires human approval** (see §10).

### 7.5 `release.yml`

Triggered on merge to `main` when `versions.toml` changed.

1. `dist.sh`: `x.py dist` for each host (`x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu`, `aarch64-apple-darwin` if a macOS runner is available).
2. Version string: `<rust-version>-mos.<N>`.
3. Publish as a GitHub release (`gh release create`) plus checksums. Provide `install.sh` that unpacks and runs `rustup toolchain link mos-stable <path>` (and `mos-beta`).
4. Build and push the Docker image (`docker/`, toolchain + llvm-mos SDK, ready for `cargo build --target mos-c64-none`) to `ghcr.io`, tagged `<rust-version>-mos.<N>` and `stable`/`beta`.
5. Later phase: generate rustup channel manifests to support `RUSTUP_DIST_SERVER`.

## 8. Claude Code in CI

Claude Code is invoked **only** when a patch series does not apply or a build fails after applying. It runs in headless mode (`claude -p`) on the runner, with the API key stored as a GitHub Actions secret.

Guardrails:

- Runs in an isolated worktree; has no push rights on `main`; the workflow, not Claude, pushes the PR branch.
- Restricted tools: read/edit files, `git` (no push), `scripts/*`. No network access beyond what the scripts need.
- Bounded number of turns; on exhaustion, the workflow opens an issue with logs instead of a PR.
- Must only modify code in the conflicted hunks or the minimal surrounding context. Must not change behaviour of non-MOS targets.
- Must end with the relevant tests green and patches regenerated via `regen-patches.sh`.
- Must write `work/claude-report.md` explaining each conflict and the chosen resolution; the workflow includes it in the PR body.

Prompts are stored in `ci/claude/` and versioned like code.

## 9. Test tiers

1. **LLVM**: `llvm-lit` on `llvm/test/CodeGen/MOS` and `llvm/test/MC/MOS`.
2. **Rust build**: `core` and `alloc` compile for every MOS target.
3. **Runtime**: each program in `tests/programs/` is built for `mos-sim` and executed with the SDK simulator; stdout and exit code are compared with the expected files.
4. **Code size**: size of each test binary compared with `tests/size-baseline.json`; a regression above a threshold (default 5 %) fails the run. Baseline updates require an explicit commit.
5. **Smoke test with vanilla cargo**: create a fresh crate targeting a MOS platform and `cargo build --release` it with the produced toolchain.

A richer test suite is what makes auto-merge safe; grow `tests/programs/` over time (integer widths incl. `i128`, floats, `alloc` collections, panics, interrupts/`asm!` where supported).

## 10. Merge and release policy

- **Rust-only syncs and MOS backend syncs**: auto-merge if all test tiers pass. Released first on the `beta` channel; promoted to `stable` automatically after 7 days without a regression issue.
- **LLVM bumps**: always require a human approval on the PR before merge.
- **Failures**: any failed workflow opens (or updates) a single issue per channel with logs and the Claude report; it is closed automatically by the next successful run.

## 11. Infrastructure

- GitHub-hosted runners (free for public repositories) are the default: `ubuntu-24.04` for x86_64 Linux, `ubuntu-24.04-arm` for aarch64 Linux, `macos-14` for aarch64 macOS. Free disk space first (remove preinstalled SDKs) and respect the 6 h job limit.
- A self-hosted runner with label `mos-builder` is optional (e.g. the maintainer's machine); workflows must work on both.
- LLVM installs are cached by key (§3.4) as assets of a dedicated release `llvm-cache` of this repository (durable, plain HTTPS download); the GitHub Actions cache is only a short-lived speed-up on top. `sccache` for rustc where useful.
- Upstream sources are fetched with plain `git`; the GitHub API (through `gh`) is used only for this repository (PRs, issues, releases).
- Storage and retention of binaries: see `docs/git-and-distribution.md`.

## 12. Implementation phases

Complete each phase fully, including its acceptance criteria, before starting the next. Commit in small, reviewable steps.

**Phase 1 — Manual bootstrap (local, interactive).**
Build the first `rust-X.Y-mos` LLVM as described in §7.4, then patch rustc for the MOS targets.
*Done when:* a toolchain built from `patches/` + `versions.toml` by the scripts compiles and runs `tests/programs/hello` on `mos-sim`, with vanilla cargo.

**Phase 2 — Reproducible scripts.**
Implement all scripts of §6 and the test tiers of §9.
*Done when:* on a clean machine, `fetch → apply → build-llvm → build-sdk → build-rust → test → dist` succeeds with no manual step.

**Phase 3 — CI for Rust syncs and releases.**
`watch.yml`, `sync-rust.yml`, `release.yml` (including the Docker image), `github.sh`.
*Done when:* a new Rust point release produces a PR and, after merge, a published toolchain without intervention (Claude Code not yet enabled).

**Phase 4 — MOS backend sync.**
`sync-mos-backend.yml` with deferral logic.

**Phase 5 — Claude Code conflict resolution.**
Headless invocation, guardrails, prompts in `ci/claude/`, reports in PRs. Test it by replaying a past conflict.

**Phase 6 — LLVM bumps.**
`llvm-bump.yml`, driven from beta. *Done when:* a simulated bump (previous → current Rust LLVM branch) completes end to end.

**Phase 7 — Distribution polish.**
Beta→stable promotion, rustup manifests, additional hosts.

## 13. Conventions for Claude Code

- Read `versions.toml` first in every session to know the current state.
- Never edit files under `work/` as a way to fix something permanently; the fix belongs in `patches/`, `scripts/` or `config/`.
- Commit messages: `<area>: <summary>` where area is one of `llvm`, `rust`, `scripts`, `ci`, `tests`, `docs`.
- Ask the maintainer before: changing a design decision in §3, touching behaviour of non-MOS targets, relaxing a test threshold, or adding a cargo patch.
- Keep this plan up to date when reality diverges from it; propose the edit in the same PR.
