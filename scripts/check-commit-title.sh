#!/usr/bin/env bash
# Check that commit titles are Conventional Commits: `type(scope)!: subject`.
#
# main is squash-merged with the PR title as the commit subject, so CI checks
# the PR title. See docs/decisions.md entry 31.
#
# Usage:
#   scripts/check-commit-title.sh "<title>" ...
#   git log --format=%s origin/main..HEAD | scripts/check-commit-title.sh
set -euo pipefail

types='feat|fix|docs|chore|ci|refactor|perf|revert'
conventional="^(${types})(\([a-z0-9][a-z0-9._/-]*\))?!?: [^ ].*"
github_revert='^Revert ".+"'   # what GitHub's Revert button titles the PR

if (( $# )); then
  titles=("$@")
else
  mapfile -t titles
fi

bad=0
for t in "${titles[@]}"; do
  if [[ $t =~ $conventional || $t =~ $github_revert ]]; then
    echo "ok   $t"
  else
    echo "BAD  $t" >&2
    bad=1
  fi
done

if (( bad )); then
  echo >&2
  echo "Expected:  type(scope): subject      e.g.  fix(traefik): turn on access logs" >&2
  echo "Types:     ${types//|/, }" >&2
  echo "Scope is optional, lowercase: a service or project namespace (velero, proj-wsj27)." >&2
  echo "'!' after the type/scope marks a breaking change. See CLAUDE.md, \"Commit titles\"." >&2
  exit 1
fi
