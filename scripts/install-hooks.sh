#!/usr/bin/env bash
# Install the repo's git hooks (opt-in — git never runs hooks from a clone).
#
# Points core.hooksPath at scripts/hooks/, so the hooks are version-controlled
# rather than hidden in .git/hooks. Undo with: git config --unset core.hooksPath
#
# Usage:
#   scripts/install-hooks.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath scripts/hooks
chmod +x scripts/hooks/*
echo "Hooks enabled (core.hooksPath=scripts/hooks):"
ls -1 scripts/hooks
