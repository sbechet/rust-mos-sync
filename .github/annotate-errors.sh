#!/usr/bin/env bash
# Publishes the interesting part of failed build logs as workflow annotations,
# which (unlike job logs) can be read without authentication.
# Usage: annotate-errors.sh <log>...
set -uo pipefail
for f in "$@"; do
    [ -s "$f" ] || continue
    # Error lines with a little context, else the tail of the log.
    body=$(grep -n -iE -B2 -A6 '(^|[^a-z])(error|FAILED|failed|panicked|undefined reference|No such file)' "$f" | head -c 3500)
    [ -n "$body" ] || body=$(tail -c 3500 "$f")
    body=${body//'%'/'%25'}; body=${body//$'\r'/}; body=${body//$'\n'/'%0A'}
    echo "::error title=$(basename "$f")::$body"
    # The tail too, since the first error is not always the real one.
    tail=$(tail -n 40 "$f" | head -c 3500)
    tail=${tail//'%'/'%25'}; tail=${tail//$'\r'/}; tail=${tail//$'\n'/'%0A'}
    echo "::error title=$(basename "$f") (tail)::$tail"
done
