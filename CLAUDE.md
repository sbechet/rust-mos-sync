# rust-mos-sync

Keeps a MOS 6502 Rust toolchain (llvm-mos backend) in sync with Rust stable/beta.
The full design lives in [PLAN.md](PLAN.md) — read it, then `versions.toml`, at the start of every session.

Conventions (see PLAN.md §13):
- Fixes go in `patches/`, `scripts/` or `config/`, never only in `work/`.
- Commit messages: `<area>: <summary>`, area ∈ llvm, rust, scripts, ci, tests, docs.
- Scripts: bash, `set -euo pipefail`, idempotent; exit 0 ok, 1 error, 2 patch conflict, 3 test failure.
- MOS targets ship `core`, `alloc`, `compiler_builtins` only — never `std`.
- Ask the maintainer before changing a §3 design decision, touching non-MOS targets,
  relaxing a test threshold or adding a cargo patch.
