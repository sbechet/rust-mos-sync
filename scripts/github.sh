#!/usr/bin/env bash
# github.sh <subcommand> ...
#
# Small PR/issue helpers via the `gh` CLI (PLAN.md §6, §10), used by the
# sync-rust/llvm-bump/sync-mos-backend workflows so they stay idempotent
# across re-runs instead of piling up duplicate PRs or issues. Needs `gh`
# and GH_TOKEN (the workflows already export both); the repo is taken from
# the current git remote unless GH_REPO is set.
#
# Subcommands:
#   pr-open <branch> <title> <body-file>
#       Opens a PR from <branch> to main, or updates the existing one if a
#       PR from that branch is already open. Prints the PR URL.
#   issue-open <label> <title> <body-file>
#       Opens a new tracking issue with <label>, or comments on the one
#       already open with it instead of duplicating (PLAN.md §10: "a single
#       issue per channel"). The label must already exist on the repo.
#       Prints the issue URL.
#   issue-close <label> [<comment>]
#       Closes every open issue with <label> (there should be at most one),
#       with an optional closing comment - called on the next successful
#       run after a failure (PLAN.md §10: "closed automatically by the next
#       successful run").
. "$(dirname "$0")/lib.sh"
need gh

cmd="${1:?usage: github.sh <pr-open|issue-open|issue-close> ...}"
shift

case "$cmd" in
    pr-open)
        branch="${1:?usage: github.sh pr-open <branch> <title> <body-file>}"
        title="${2:?title required}"
        body_file="${3:?body file required}"
        existing=$(gh pr list --head "$branch" --state open --json url --jq '.[0].url // empty')
        if [ -n "$existing" ]; then
            gh pr edit "$existing" --title "$title" --body-file "$body_file" >/dev/null
            log "updated existing PR: $existing"
            echo "$existing"
        else
            gh pr create --head "$branch" --base main --title "$title" --body-file "$body_file"
        fi
        ;;
    issue-open)
        label="${1:?usage: github.sh issue-open <label> <title> <body-file>}"
        title="${2:?title required}"
        body_file="${3:?body file required}"
        existing=$(gh issue list --label "$label" --state open --json url --jq '.[0].url // empty')
        if [ -n "$existing" ]; then
            gh issue comment "$existing" --body-file "$body_file" >/dev/null
            log "commented on existing issue: $existing"
            echo "$existing"
        else
            gh issue create --label "$label" --title "$title" --body-file "$body_file"
        fi
        ;;
    issue-close)
        label="${1:?usage: github.sh issue-close <label> [comment]}"
        comment="${2:-}"
        numbers=$(gh issue list --label "$label" --state open --json number --jq '.[].number')
        if [ -z "$numbers" ]; then
            log "no open issue labeled $label"
        else
            while read -r n; do
                [ -n "$n" ] || continue
                [ -n "$comment" ] && gh issue comment "$n" --body "$comment" >/dev/null
                gh issue close "$n" >/dev/null
                log "closed issue #$n (label $label)"
            done <<< "$numbers"
        fi
        ;;
    *)
        die "unknown subcommand: $cmd (expected pr-open, issue-open or issue-close)"
        ;;
esac
