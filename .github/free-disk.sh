#!/usr/bin/env bash
# Frees ~30 GB on GitHub-hosted Ubuntu runners (LLVM + rustc need more than
# the ~14 GB available by default). PLAN.md §11.
set -euo pipefail
df -h / | tail -1
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /usr/local/.ghcup \
    /opt/hostedtoolcache/CodeQL /usr/local/share/boost /usr/share/swift \
    /usr/local/share/powershell /usr/local/share/chromium /usr/local/lib/node_modules
sudo docker image prune --all --force >/dev/null 2>&1 || true
df -h / | tail -1
