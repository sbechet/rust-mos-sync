#!/usr/bin/env bash
# detect.sh [--rust-only]
#
# Compares upstream state against versions.toml (PLAN.md §7.1) using plain
# `git ls-remote`/shallow fetches, no local checkout of the full trees.
# Prints one classified line per action needed, machine-readable:
#   ACTION <kind> <channel> <detail...>
# kind is one of: sync-rust, llvm-bump, sync-mos-backend. A run with nothing
# to do prints nothing and exits 0.
#
# --rust-only skips the llvm-mos check (the slow part, ~5-6 minutes even
# when nothing changed - see below) and only looks at rust.stable/rust.beta,
# a few seconds. sync-rust.yml uses this: it only cares whether ITS channel
# needs a Rust sync, not about llvm-mos. watch.yml's daily cron runs the
# full check.
. "$(dirname "$0")/lib.sh"
need git python3

rust_only=0
[ "${1:-}" = --rust-only ] && rust_only=1

# llvm_branch_of <repo-clone> <rust-ref>
# Prints "<llvm_branch> <llvm_commit>" for a rust-lang/rust ref already
# fetched into <repo-clone> (needs the tree, not just the commit).
llvm_branch_of() {
    local clone="$1" ref="$2" commit branch
    commit=$(git -C "$clone" rev-parse "$ref:src/llvm-project" 2>/dev/null) || return 1
    branch=$(git -C "$clone" show "$ref:.gitmodules" 2>/dev/null \
        | awk '/path = src\/llvm-project/{f=1} f && /branch = /{print $3; exit}')
    [ -n "$branch" ] || return 1
    echo "$branch $commit"
}

rust_probe="$WORK/detect-rust-probe"
if [ ! -d "$rust_probe/.git" ]; then
    git init -q "$rust_probe"
    git -C "$rust_probe" remote add origin "$RUST_URL"
fi

# The branch patches/llvm/ actually applies to - NOT rust.<channel>.llvm_branch,
# which only says what that channel's own PREVIOUS sync recorded and can be
# wrong from the start (e.g. beta routinely sits on a newer LLVM branch than
# what patches/llvm/ was ever extracted for; comparing to its own prior value
# would call that "no bump needed" forever and retry - and fail - a build
# every day. See docs/backlog.md).
patched_branch=$(ver_get llvm_mos.patched_branch)

# --- rust.stable: newest vX.Y.Z tag -------------------------------------
latest_stable=$(git ls-remote --tags "$RUST_URL" \
    | awk '{print $2}' | sed -n 's#^refs/tags/\(1\.[0-9]\+\.[0-9]\+\)$#\1#p' \
    | sort -V | tail -1)
current_stable=$(ver_get rust.stable.tag)
if [ -n "$latest_stable" ] && [ "$latest_stable" != "$current_stable" ]; then
    git -C "$rust_probe" fetch -q --depth=1 origin "refs/tags/$latest_stable:refs/tags/$latest_stable"
    if read -r llvm_branch llvm_commit < <(llvm_branch_of "$rust_probe" "$latest_stable"); then
        if [ "$llvm_branch" = "$patched_branch" ]; then
            echo "ACTION sync-rust stable $latest_stable $llvm_branch $llvm_commit"
        else
            echo "ACTION llvm-bump stable $latest_stable $llvm_branch $llvm_commit"
        fi
    else
        warn "could not resolve src/llvm-project for stable tag $latest_stable"
    fi
fi

# --- rust.beta: the `beta` branch head -----------------------------------
latest_beta=$(git ls-remote "$RUST_URL" refs/heads/beta | awk '{print $1}')
current_beta=$(ver_get rust.beta.commit)
if [ -n "$latest_beta" ] && [ "$latest_beta" != "$current_beta" ]; then
    git -C "$rust_probe" fetch -q --depth=1 origin "$latest_beta"
    if read -r llvm_branch llvm_commit < <(llvm_branch_of "$rust_probe" "$latest_beta"); then
        if [ "$llvm_branch" = "$patched_branch" ]; then
            echo "ACTION sync-rust beta $latest_beta $llvm_branch $llvm_commit"
        else
            echo "ACTION llvm-bump beta $latest_beta $llvm_branch $llvm_commit"
        fi
    else
        warn "could not resolve src/llvm-project for beta $latest_beta"
    fi
fi

# --- llvm-mos: new commits on main since llvm_mos.last_synced -------------
# Informational only for now: sync-mos-backend.yml (PLAN.md §7.3, Phase 4)
# does not exist yet, so this never dispatches anything, just reports.
#
# llvm-mos main has hundreds of thousands of commits (it merges upstream
# LLVM continuously): a plain history walk, even treeless, is too slow.
# --shallow-exclude=<sha> would be the right primitive but GitHub's server
# errors ("expected 'packfile'") combining it with a partial-clone filter
# against this repo; --shallow-since=<date> works, so fetch last_synced by
# itself first (cheap: one commit) just to read its date. Still ~5-6
# minutes end to end - acceptable for a daily cron, not for anything more
# frequent. Caching this probe clone between runs (e.g. actions/cache, like
# ccache) would make it incremental; not done yet, see docs/backlog.md.
last_synced=$(ver_get llvm_mos.last_synced)
if [ "$rust_only" = 0 ] && [ -n "$last_synced" ]; then
    mos_probe="$WORK/detect-llvm-mos-probe"
    if [ ! -d "$mos_probe/.git" ]; then
        git init -q --bare "$mos_probe"
        git -C "$mos_probe" remote add origin "$LLVM_MOS_URL"
    fi
    if git -C "$mos_probe" fetch -q --depth=1 --filter=blob:none origin "$last_synced" 2>/dev/null; then
        since=$(git -C "$mos_probe" log -1 --format=%cI "$last_synced")
        git -C "$mos_probe" fetch -q --filter=blob:none "--shallow-since=$since" \
            origin "+refs/heads/main:refs/remotes/origin/main"
        new_count=$(git -C "$mos_probe" rev-list --count \
            "$last_synced..refs/remotes/origin/main" -- \
            llvm/lib/Target/MOS llvm/test/CodeGen/MOS llvm/test/MC/MOS 2>/dev/null || echo 0)
        [ "${new_count:-0}" -gt 0 ] && echo "ACTION sync-mos-backend main $new_count new commit(s) touching MOS paths since $last_synced"
    else
        warn "llvm_mos.last_synced ($last_synced) not found on llvm-mos; was it rewritten?"
    fi
fi
