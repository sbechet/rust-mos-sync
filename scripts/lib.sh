# shellcheck shell=bash
# Shared helpers for rust-mos-sync scripts. Source it, do not execute it.
#   . "$(dirname "$0")/lib.sh"

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$ROOT/work}"
CACHE="${CACHE:-$ROOT/cache}"
VERSIONS="${VERSIONS:-$ROOT/versions.toml}"

# Exit codes (PLAN.md §6)
EXIT_OK=0
EXIT_ERROR=1
EXIT_CONFLICT=2
EXIT_TEST=3

# Upstream remotes, fetched with plain git (PLAN.md §11)
RUST_URL="${RUST_URL:-https://github.com/rust-lang/rust.git}"
RUST_LLVM_URL="${RUST_LLVM_URL:-https://github.com/rust-lang/llvm-project.git}"
LLVM_MOS_URL="${LLVM_MOS_URL:-https://github.com/llvm-mos/llvm-mos.git}"
LLVM_MOS_SDK_URL="${LLVM_MOS_SDK_URL:-https://github.com/llvm-mos/llvm-mos-sdk.git}"
LLVM_MOS_SDK_URL_RELEASES="${LLVM_MOS_SDK_URL_RELEASES:-https://github.com/llvm-mos/llvm-mos-sdk/releases}"

# This repository on GitHub; LLVM installs are cached as assets of its
# `llvm-cache` release (docs/git-and-distribution.md §2.3).
GITHUB_REPO="${GITHUB_REPO:-sbechet/rust-mos-sync}"
LLVM_CACHE_URL="${LLVM_CACHE_URL:-https://github.com/$GITHUB_REPO/releases/download/llvm-cache}"

# Parallelism: default to the number of cores; link jobs are kept low because
# linking LLVM is memory bound.
JOBS="${JOBS:-$(nproc)}"

_ts() { date -u +%H:%M:%S; }
log()  { printf '[%s] %s\n' "$(_ts)" "$*" >&2; }
warn() { printf '[%s] warning: %s\n' "$(_ts)" "$*" >&2; }
die()  { printf '[%s] error: %s\n' "$(_ts)" "$*" >&2; exit "${2:-$EXIT_ERROR}"; }

need() {
    local t
    for t in "$@"; do
        command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t"
    done
}

# llvm_version_of_branch <rustc/NN.N-date>  ->  NN.N
llvm_version_of_branch() { sed -n 's#^rustc/\([0-9]*\.[0-9]*\)-.*#\1#p' <<<"$1"; }

# llvm_series_dir <channel> [--allow-missing]
# patches/llvm/<NN.N>: the MOS patch series for that channel's LLVM branch.
# Dies if there is none (that channel needs an llvm-bump first) unless
# --allow-missing: building LLVM with no series would silently drop MOS.
# One directory per LLVM version, so stable can stay on the old branch while
# beta's bump is prepared (PLAN.md §3.5).
llvm_series_dir() {
    local channel="$1" branch ver
    branch=$(ver_get "rust.$1.llvm_branch")
    ver=$(llvm_version_of_branch "$branch")
    [ -n "$ver" ] || die "rust.$1.llvm_branch ('$branch') is not a rustc/NN.N-date branch"
    if [ "${2:-}" != --allow-missing ] && ! ls "$ROOT/patches/llvm/$ver"/*.patch >/dev/null 2>&1; then
        die "no MOS patch series for $channel's LLVM branch $branch (patches/llvm/$ver); it needs an llvm-bump" "$EXIT_CONFLICT"
    fi
    echo "$ROOT/patches/llvm/$ver"
}

# ver_get <dotted.key>        e.g. ver_get rust.stable.tag
# Prints the value; arrays are printed one element per line. Empty if unset.
ver_get() {
    python3 - "$VERSIONS" "$1" <<'PY'
import sys, tomllib
path, key = sys.argv[1], sys.argv[2]
with open(path, "rb") as f:
    node = tomllib.load(f)
for part in key.split("."):
    if not isinstance(node, dict) or part not in node:
        sys.exit(0)
    node = node[part]
if isinstance(node, list):
    print("\n".join(str(x) for x in node))
elif isinstance(node, bool):
    print("true" if node else "false")
else:
    print(node)
PY
}

# ver_set <dotted.key> <value>
# Sets a scalar (strings are quoted, integers kept bare) inside an existing
# [section]; the key is added to the section if missing. Comments are kept.
# For arrays pass a TOML literal and prefix it with "raw:", e.g. raw:["a","b"].
ver_set() {
    python3 - "$VERSIONS" "$1" "$2" <<'PY'
import re, sys
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
section, name = key.rsplit(".", 1)
if value.startswith("raw:"):
    literal = value[4:]
elif re.fullmatch(r"-?\d+", value):
    literal = value
else:
    literal = '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'
lines = open(path).read().split("\n")
header = f"[{section}]"
try:
    start = next(i for i, l in enumerate(lines) if l.strip() == header)
except StopIteration:
    sys.exit(f"versions.toml: section {header} not found")
end = next((i for i in range(start + 1, len(lines)) if lines[i].lstrip().startswith("[")), len(lines))
pat = re.compile(rf"^(\s*{re.escape(name)}\s*=\s*)(.*?)(\s*#.*)?$")
for i in range(start + 1, end):
    m = pat.match(lines[i])
    if m:
        lines[i] = m.group(1) + literal + (m.group(3) or "")
        break
else:
    ins = end
    while ins > start + 1 and lines[ins - 1].strip() == "":
        ins -= 1
    lines.insert(ins, f"{name} = {literal}")
open(path, "w").write("\n".join(lines))
PY
}

# LLVM version ("22.1") from a rustc/NN.N-YYYY-MM-DD branch name.
llvm_version_of_branch() {
    local b="${1#rustc/}"
    printf '%s\n' "${b%%-*}"
}

# Host triple as rustc names it.
host_triple() {
    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64)  echo x86_64-unknown-linux-gnu ;;
        Linux-aarch64) echo aarch64-unknown-linux-gnu ;;
        Darwin-arm64)  echo aarch64-apple-darwin ;;
        *) die "unsupported host $(uname -s)-$(uname -m)" ;;
    esac
}
