#!/bin/bash
# Install seahelm's git hooks by symlinking them into .git/hooks so they always
# reflect the committed versions in scripts/hooks/. Idempotent.
#
# Usage: scripts/install-hooks.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GIT_DIR="$(git -C "$ROOT" rev-parse --git-dir)"
# Resolve to absolute (git-dir may be relative to ROOT).
case "$GIT_DIR" in /*) : ;; *) GIT_DIR="$ROOT/$GIT_DIR" ;; esac

mkdir -p "$GIT_DIR/hooks"
for hook in "$ROOT"/scripts/hooks/*; do
  name="$(basename "$hook")"
  chmod +x "$hook"
  ln -sf "../../scripts/hooks/$name" "$GIT_DIR/hooks/$name"
  echo "installed hook: $name -> scripts/hooks/$name"
done
