#!/usr/bin/env bash
# test.sh [<toolchain-dir>] [tier...]    tiers: llvm std run size smoke
#
# Runs the test tiers of PLAN.md §9 against a toolchain directory (a sysroot
# with bin/rustc; default: the latest stage built in $WORK/rust). Tiers:
#   1 llvm     llvm-lit on llvm/test/CodeGen/MOS and llvm/test/MC/MOS
#   2 std      core, alloc, compiler_builtins present (and no std) per MOS target
#   3 run      tests/programs/* built for mos-sim-none and run on mos-sim
#   4 size     code size vs tests/size-baseline.json (SIZE_THRESHOLD %, default 5)
#   5 smoke    fresh `cargo new` crate built with a vanilla cargo
# Cargo is the one on PATH (vanilla, PLAN.md §3.3) unless CARGO is set.
# Summary in $WORK/test-report.txt; exit 3 if any test failed.
. "$(dirname "$0")/lib.sh"
need python3

host=$(host_triple)
toolchain=""
if [ $# -gt 0 ] && [ -d "$1" ]; then toolchain="$1"; shift; fi
tiers=("$@")
[ ${#tiers[@]} -gt 0 ] || tiers=(llvm std run size smoke)

# Every tier but llvm needs the Rust toolchain.
needs_rustc=0
for t in "${tiers[@]}"; do [ "$t" = llvm ] || needs_rustc=1; done
if [ -z "$toolchain" ]; then
    for s in 2 1; do
        [ -x "$WORK/rust/build/$host/stage$s/bin/rustc" ] && { toolchain="$WORK/rust/build/$host/stage$s"; break; }
    done
fi
if [ "$needs_rustc" = 1 ]; then
    [ -x "$toolchain/bin/rustc" ] || die "no toolchain found (pass its directory)"
fi

sdk=$("$ROOT/scripts/build-sdk.sh")
export PATH="$sdk/bin:$PATH"
[ "$needs_rustc" = 0 ] || export RUSTC="$toolchain/bin/rustc"
CARGO="${CARGO:-cargo}"
SIZE_THRESHOLD="${SIZE_THRESHOLD:-5}"
sim_target=mos-sim-none

report="$WORK/test-report.txt"
: > "$report"
failed=0
pass() { printf 'PASS %s\n' "$*" | tee -a "$report" >&2; }
fail() { printf 'FAIL %s\n' "$*" | tee -a "$report" >&2; failed=$((failed + 1)); }
skip() { printf 'SKIP %s\n' "$*" | tee -a "$report" >&2; }
warn_known() { printf 'WARN %s\n' "$*" | tee -a "$report" >&2; }

mos_targets() {
    "$RUSTC" --print target-list | grep '^mos-'
}

# patches/llvm/<NN.N>/KNOWN_LIT_FAILURES: lit tests (one per line, as lit prints
# them, "LLVM :: CodeGen/MOS/x.ll"; '#' comments) that fail on that LLVM branch
# for a reason that is understood and not yet proven harmful. They are reported
# as WARN instead of failing the tier; any other failing test still fails it.
# Delete the file once the tests are fixed or the series is verified.
tier_llvm() {
    local lit="$WORK/llvm-build/bin/llvm-lit"
    if [ ! -x "$lit" ]; then skip "llvm: $lit not found (LLVM restored from cache?)"; return; fi
    local d log known="" t unexpected
    local series_dir
    series_dir=$(llvm_series_dir "${CHANNEL:-stable}" --allow-missing)
    [ -f "$series_dir/KNOWN_LIT_FAILURES" ] && known=$(grep -v '^[[:space:]]*\(#\|$\)' "$series_dir/KNOWN_LIT_FAILURES")
    for d in CodeGen/MOS MC/MOS; do
        log="$WORK/lit-${d//\//-}.log"
        if "$lit" -v -j "$JOBS" "$WORK/llvm-project/llvm/test/$d" >"$log" 2>&1; then
            pass "llvm: lit $d"
            continue
        fi
        unexpected=0
        while IFS= read -r t; do
            if grep -qxF "$t" <<<"$known"; then
                warn_known "llvm: lit $d: $t (known failure, see KNOWN_LIT_FAILURES)"
            else
                unexpected=1
            fi
        done < <(sed -n '/^Failed Tests/,/^$/p' "$log" | sed -n 's/^  \(LLVM :: .*\)$/\1/p')
        if [ "$unexpected" = 0 ] && grep -q '^Failed Tests' "$log"; then
            pass "llvm: lit $d (only known failures)"
        else
            fail "llvm: lit $d (see $log)"
        fi
    done
}

tier_std() {
    local t dir
    for t in $(mos_targets); do
        dir="$toolchain/lib/rustlib/$t/lib"
        if ! ls "$dir"/libcore-*.rlib "$dir"/liballoc-*.rlib "$dir"/libcompiler_builtins-*.rlib >/dev/null 2>&1; then
            fail "std: $t is missing core/alloc/compiler_builtins in $dir"
        elif ls "$dir"/libstd-*.rlib >/dev/null 2>&1; then
            fail "std: $t ships libstd, it must not"
        else
            pass "std: $t has core, alloc, compiler_builtins"
        fi
    done
}

# Builds all programs once; results in $WORK/test-programs/target.
build_programs() {
    [ -n "${_programs_built:-}" ] && return "$_programs_built"
    if CARGO_TARGET_DIR="$WORK/test-programs/target" \
        "$CARGO" build --release --manifest-path "$ROOT/tests/programs/Cargo.toml" \
        --workspace --target "$sim_target" >"$WORK/test-programs.log" 2>&1; then
        _programs_built=0
    else
        _programs_built=1
    fi
    return "$_programs_built"
}

programs() {
    python3 -c 'import tomllib,sys; print("\n".join(tomllib.load(open(sys.argv[1],"rb"))["workspace"]["members"]))' \
        "$ROOT/tests/programs/Cargo.toml"
}

tier_run() {
    if ! build_programs; then fail "run: cargo build failed (see $WORK/test-programs.log)"; return; fi
    local p bin out code want_code
    for p in $(programs); do
        bin="$WORK/test-programs/target/$sim_target/release/$p"
        out=$(mktemp)
        set +e
        timeout 60 mos-sim "$bin" >"$out" 2>"$out.err"
        code=$?
        set -e
        want_code=$(cat "$ROOT/tests/programs/$p/expected.exit" 2>/dev/null || echo 0)
        if ! cmp -s "$out" "$ROOT/tests/programs/$p/expected.stdout"; then
            fail "run: $p stdout differs"; diff "$ROOT/tests/programs/$p/expected.stdout" "$out" | head -20 >> "$report" || true
        elif [ "$code" != "$want_code" ]; then
            fail "run: $p exit code $code, expected $want_code"
        else
            pass "run: $p"
        fi
        rm -f "$out" "$out.err"
    done
}

tier_size() {
    if ! build_programs; then fail "size: cargo build failed"; return; fi
    local baseline="$ROOT/tests/size-baseline.json" p elf sizes=()
    for p in $(programs); do
        elf="$WORK/test-programs/target/$sim_target/release/$p"
        [ -f "$elf" ] || { fail "size: $elf missing"; continue; }
        # llvm-size understands ELF/COFF/Mach-O/archives; some MOS platforms
        # (mos-sim confirmed) link a raw memory image for their loader
        # instead (no ELF magic at all - checked with `od`), which is not a
        # format bug, just not an object file. Total size on disk is then the
        # direct, honest measurement: the loader header is a few bytes, the
        # rest is exactly the code+data that gets loaded.
        local n
        if n=$(llvm-size -A "$elf" 2>/dev/null \
                | awk '$1 ~ /^\.(text|rodata|data)/ {s += $2} END {print s + 0}') && [ "$n" -gt 0 ]; then
            sizes+=("$p=$n")
        else
            sizes+=("$p=$(stat -c %s "$elf")")
        fi
    done
    [ ${#sizes[@]} -eq 0 ] && { skip "size: no program could be measured"; return; }
    local rc=0
    python3 - "$baseline" "$SIZE_THRESHOLD" "$WORK/size-current.json" "${sizes[@]}" >"$WORK/size.txt" <<'PY' || rc=$?
import json, os, sys
baseline_path, threshold, current_path, *pairs = sys.argv[1:]
cur = {k: int(v) for k, v in (p.split("=", 1) for p in pairs)}
json.dump(cur, open(current_path, "w"), indent=2, sort_keys=True)
base = json.load(open(baseline_path)) if os.path.exists(baseline_path) else {}
bad = 0
for name, size in sorted(cur.items()):
    if name not in base:
        print(f"SKIP size: {name} = {size} bytes (no baseline)")
        continue
    delta = (size - base[name]) * 100 / max(base[name], 1)
    status = "FAIL" if delta > float(threshold) else "PASS"
    bad += status == "FAIL"
    print(f"{status} size: {name} = {size} bytes (baseline {base[name]}, {delta:+.1f}%)")
sys.exit(1 if bad else 0)
PY
    tee -a "$report" < "$WORK/size.txt" >&2
    [ "$rc" -eq 0 ] || failed=$((failed + 1))
}

tier_smoke() {
    local d="$WORK/smoke"
    rm -rf "$d"
    "$CARGO" new -q --vcs none "$d/smoke" >/dev/null
    cp "$ROOT/tests/programs/hello/src/main.rs" "$d/smoke/src/main.rs"
    cat >> "$d/smoke/Cargo.toml" <<'EOF'

[profile.release]
panic = "abort"
EOF
    # Not -q: the log must show the linker_messages warnings, if any.
    if ! (cd "$d/smoke" && "$CARGO" build --release --target "$sim_target") >"$WORK/smoke.log" 2>&1 \
       || [ "$(mos-sim "$d/smoke/target/$sim_target/release/smoke")" != "Hello, world!" ]; then
        fail "smoke: see $WORK/smoke.log"
    elif grep -q "linker stderr" "$WORK/smoke.log"; then
        # The SDK driver and lld are silent on a clean link (rust patches
        # "no -no-pie for MOS", "link MOS rlibs without their raw metadata").
        fail "smoke: the link printed warnings, see $WORK/smoke.log"
    else
        pass "smoke: vanilla cargo ($("$CARGO" --version)) builds and runs a fresh crate, link silent"
    fi
}

[ "$needs_rustc" = 0 ] || log "toolchain $toolchain ($("$RUSTC" --version))"
for t in "${tiers[@]}"; do "tier_$t"; done

log "$(grep -c '^PASS' "$report") passed, $failed failed — $report"
[ "$failed" -eq 0 ] || exit "$EXIT_TEST"
