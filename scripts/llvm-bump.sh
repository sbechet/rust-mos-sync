#!/usr/bin/env bash
# llvm-bump.sh <channel> [<rust-ref> <llvm-branch> <llvm-commit>]
# llvm-bump.sh --continue <channel>     after resolving an exit-2 conflict
#
# PLAN.md §7.4: prepare the MOS patch series for a Rust LLVM branch that has
# none yet (patches/llvm/<NN.N>/), so the channel can build again.
#
#   1. target: the arguments (as printed by `detect.sh` ACTION llvm-bump
#      lines), else the ones recorded for <channel> in versions.toml, as long
#      as that LLVM branch has no series yet;
#   2. record it in versions.toml and fetch that LLVM commit;
#   3. extract-mos-patch.sh: the llvm-mos upstream-merge commit closest to the
#      branch's fork point, as one patch (MOS delta only, no clang/lld);
#   4. apply it on the branch with `git apply --3way`. Conflicts in other
#      targets' sources and in non-MOS tests are merge noise from llvm-mos
#      being behind upstream: they are resolved to the Rust LLVM side and
#      listed in the report. Any other conflict is real work: exit 2, tree
#      left conflicted (Claude Code, Phase 5, or a human);
#   5. re-apply the adaptation patches (0002+) of the newest existing series;
#      a failure there means that adaptation no longer applies: exit 2;
#      (--continue: `git add` the resolved files in work/llvm-project, then run
#      this; it resumes at the commit of step 4)
#   6. write the series with regen-patches.sh plus patches/llvm/<NN.N>/BASE_MERGE
#      and $WORK/llvm-bump-report.md (the PR description).
#
# Building and testing the result is the caller's job (llvm-bump.yml).
. "$(dirname "$0")/lib.sh"
need git python3

continue_=0
if [ "${1:-}" = --continue ]; then continue_=1; shift; fi
channel="${1:?usage: llvm-bump.sh [--continue] <stable|beta> [<rust-ref> <llvm-branch> <llvm-commit>]}"
ref="${2:-}"; branch="${3:-}"; commit="${4:-}"
state="$WORK/llvm-bump.state"
if [ "$continue_" = 1 ]; then
    [ -f "$state" ] || die "no $state: run scripts/llvm-bump.sh $channel first"
    . "$state"
fi

if [ "$continue_" = 0 ]; then
    if [ -z "$ref" ]; then
        line=$("$ROOT/scripts/detect.sh" --rust-only | awk -v ch="$channel" '$2 == "llvm-bump" && $3 == ch {print; exit}')
        if [ -n "$line" ]; then
            read -r _ _ _ ref branch commit <<< "$line"
        else
            branch=$(ver_get "rust.$channel.llvm_branch")
            commit=$(ver_get "rust.$channel.llvm_commit")
            if [ "$channel" = stable ]; then ref=$(ver_get rust.stable.tag); else ref=$(ver_get rust.beta.commit); fi
            if ls "$ROOT/patches/llvm/$(llvm_version_of_branch "$branch")"/*.patch >/dev/null 2>&1; then
                log "$channel's LLVM branch $branch already has a patch series; nothing to bump"
                exit 0
            fi
        fi
    fi
    [ -n "$branch" ] && [ -n "$commit" ] || die "no target LLVM branch/commit for $channel"
    version=$(llvm_version_of_branch "$branch")
    [ -n "$version" ] || die "cannot read an LLVM version from '$branch'"
    series="$ROOT/patches/llvm/$version"
    if ls "$series"/*.patch >/dev/null 2>&1; then
        die "$series already exists; remove it to redo this bump"
    fi
    log "bumping $channel to LLVM $version ($branch @ ${commit:0:12}), rust ref $ref"


fi
# (idempotent, so --continue repeats it harmlessly)
if [ "$channel" = stable ]; then
    ver_set rust.stable.tag "$ref"; ver_set release.mos_revision 1
else
    ver_set rust.beta.commit "$ref"
fi
ver_set "rust.$channel.llvm_branch" "$branch"
ver_set "rust.$channel.llvm_commit" "$commit"
version=$(llvm_version_of_branch "$branch")
series="$ROOT/patches/llvm/$version"

# Adaptation patches of the newest existing series (0001 is the backend itself).
prev=$(find "$ROOT/patches/llvm" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
adapt=()
if [ -n "$prev" ]; then
    while IFS= read -r p; do adapt+=("$p"); done < <(find "$prev" -maxdepth 1 -name '0*.patch' | sort | tail -n +2)
fi

report="$WORK/llvm-bump-report.md"
dir="$WORK/llvm-project"
gitc() { git -C "$dir" -c user.name=rust-mos-sync -c user.email=rust-mos-sync@localhost "$@"; }

if [ "$continue_" = 0 ]; then
    "$ROOT/scripts/fetch.sh" llvm "$channel"
    read -r merge parent < <("$ROOT/scripts/extract-mos-patch.sh" "$branch")
    printf 'ref=%q\nbranch=%q\ncommit=%q\nmerge=%q\nparent=%q\n' "$ref" "$branch" "$commit" "$merge" "$parent" > "$state"

    git -C "$dir" am --abort >/dev/null 2>&1 || true
    git -C "$dir" checkout -q --force -B mos "base-$channel"
    git -C "$dir" clean -qfdx -e /build

    resolved=()
    if ! git -C "$dir" apply --3way --index --whitespace=nowarn "$WORK/mos-extract/mos.patch" 2>"$WORK/llvm-bump-apply.log"; then
        while IFS= read -r f; do
            if [[ "$f" =~ ^llvm/test/ && ! "$f" =~ /MOS/ ]] || [[ "$f" =~ ^llvm/lib/Target/ && ! "$f" =~ ^llvm/lib/Target/MOS/ ]]; then
                git -C "$dir" checkout --ours -- "$f" && git -C "$dir" add -- "$f"
                resolved+=("$f")
            fi
        done < <(git -C "$dir" diff --name-only --diff-filter=U)
    fi
    mapfile -t left < <(git -C "$dir" diff --name-only --diff-filter=U)
    {
        echo "LLVM bump for \`$channel\`: \`$branch\` (\`${commit:0:12}\`), Rust \`$ref\`."
        echo
        echo "MOS backend extracted from llvm-mos merge \`${merge:0:12}\` (upstream parent \`${parent:0:12}\`)."
        echo
        echo "### Resolved to the Rust LLVM side (${#resolved[@]}): other targets' sources and non-MOS tests"
        echo "These are upstream drift the llvm-mos merge diff carries along, not MOS changes."
        echo '```'; printf '%s\n' "${resolved[@]}"; echo '```'
        echo "### Files outside the MOS backend touched by the patch"
        echo '```'; cat "$WORK/mos-extract/outside-mos.txt"; echo '```'
    } > "$report"
    if [ ${#left[@]} -gt 0 ]; then
        {
            echo "### Unresolved conflicts (${#left[@]}) - need a human or Claude Code"
            echo '```'; printf '%s\n' "${left[@]}"; echo '```'
        } >> "$report"
        warn "${#left[@]} conflict(s) need a manual resolution: resolve them in $dir, \`git add\` them, then run scripts/llvm-bump.sh --continue $channel (report in $report)"
        exit "$EXIT_CONFLICT"
    fi
else
    [ -z "$(git -C "$dir" diff --name-only --diff-filter=U)" ] || die "unresolved conflicts left in $dir; resolve and git add them first"
    git -C "$dir" diff --cached --quiet && die "nothing staged in $dir; was the patch applied?"
    {
        echo
        echo "### Conflicts resolved by hand"
        echo "See the diff of patches/llvm/$version/0001 against the llvm-mos extraction."
    } >> "$report"
fi

gitc commit -q -m "MOS: Add the llvm-mos backend

Extracted from llvm-mos merge ${merge:0:12} (upstream parent ${parent:0:12}) for $branch."
for p in "${adapt[@]}"; do
    if ! gitc am -3 --keep-cr "$p" >/dev/null 2>&1; then
        gitc am --abort >/dev/null 2>&1 || true
        {
            echo "### Adaptation patch no longer applies"
            echo "\`$(basename "$p")\` (from \`${prev#$ROOT/}\`) failed on $branch; it needs porting."
        } >> "$report"
        warn "$(basename "$p") does not apply on $branch"
        exit "$EXIT_CONFLICT"
    fi
done

mkdir -p "$series"
"$ROOT/scripts/regen-patches.sh" llvm "base-$channel"
echo "$merge" > "$series/BASE_MERGE"
log "series written to patches/llvm/$version; report in $report"
