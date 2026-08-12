#!/usr/bin/env bash
# Check the state of the <PLACEHOLDER> values in the manifests (docs/install.md §9).
#
# Two opposite checks, because this repo is a TEMPLATE that gets filled per
# install:
#
#   --expect-filled  (default) for an OPERATOR's filled-in clone, before
#     bootstrapping. An unfilled placeholder is NOT caught by ArgoCD: it reaches
#     Helm as a literal string, the app reports Synced/Healthy, and the component
#     fails at runtime instead — Velero authenticating as a client-id called
#     "<VELERO_CLIENT_ID>", or ESO pointing at
#     "https://<KEY_VAULT_NAME>.vault.azure.net/".
#
#   --expect-template  for THIS repo's main in CI. The placeholders are supposed
#     to still be there; what must never land is a real value committed over one.
#     Catches both a filled-in Azure identifier leaking onto the public repo and a
#     placeholder accidentally deleted.
#
# Placeholders inside comments are ignored (they document what to fill in), as
# are *.example files, which exist to be copied.
#
# Usage:
#   scripts/check-placeholders.sh --expect-template          # CI on main
#   scripts/check-placeholders.sh --expect-template --staged # pre-commit hook (INDEX)
#   scripts/check-placeholders.sh --expect-filled            # operator, pre-bootstrap
#   scripts/check-placeholders.sh --expect-filled origin/main  # ...against a pushed ref
set -euo pipefail

# Pathspecs below are cwd-relative; anchor at the repo root so the script works
# from any directory (and hard-fails outside a repo instead of scanning nothing).
cd "$(git rev-parse --show-toplevel)"

MODE=expect-filled
CACHED=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --expect-template) MODE=expect-template; shift ;;
    --expect-filled)   MODE=expect-filled;   shift ;;
    --staged)          CACHED="--cached";    shift ;;
    -h|--help)         sed -n '2,/^set /p' "$0" | sed '$d'; exit 0 ;;
    *) break ;;
  esac
done

REF="${1:-}"
if [[ -n "$CACHED" && -n "$REF" ]]; then
  echo "check-placeholders: --staged and a ref are mutually exclusive" >&2
  exit 2
fi
PATTERN='<[A-Z][A-Z0-9_]*>'

# The nine placeholders §9 fills, as "file:PLACEHOLDER". Kept explicit so that
# DELETING one is a failure too, not just replacing it with a real value.
EXPECTED=$(cat <<'EOF'
k8s/argocd/infra-apps/external-secrets.yaml:<ESO_CLIENT_ID>
k8s/argocd/infra-apps/velero.yaml:<BACKUP_STORAGE_ACCOUNT>
k8s/argocd/infra-apps/velero.yaml:<NODE_RESOURCE_GROUP>
k8s/argocd/infra-apps/velero.yaml:<SUBSCRIPTION_ID>
k8s/argocd/infra-apps/velero.yaml:<SUBSCRIPTION_ID>
k8s/argocd/infra-apps/velero.yaml:<VELERO_CLIENT_ID>
k8s/infra-manifest/dex/values.yaml:<DEX_GITHUB_CLIENT_ID>
k8s/infra-manifest/external-secrets/clustersecretstore.yaml:<KEY_VAULT_NAME>
k8s/infra-manifest/monitoring/kube-prometheus-stack-values.yaml:<GRAFANA_GITHUB_CLIENT_ID>
EOF
)

# -z NUL-delimits path and line number from the matched content, so a colon in
# the content (every `key: value` line) can never be mistaken for a field
# separator. With a ref, git still prefixes "ref:path" with a colon — that one
# is stripped by LENGTH, not by a pattern, so a ref containing regex
# metacharacters (v1.0, feature/a.b) cannot mis-strip.
#
# git grep is piped STRAIGHT into awk: command substitution silently discards
# NUL bytes, which would destroy the delimiters and make every hit invisible.
if [[ -n "$REF" ]]; then
  git rev-parse --verify --quiet "$REF" >/dev/null || {
    echo "check-placeholders: no such ref: $REF" >&2
    exit 2
  }
  SCOPE="$REF"
  strip=$(( ${#REF} + 1 ))
elif [[ -n "$CACHED" ]]; then
  SCOPE="staged index"
  strip=0
else
  SCOPE="working tree"
  strip=0
fi

# Emit "path<TAB>PLACEHOLDER" per placeholder found outside a comment, and
# "path:line:content" for display. Two records per hit, tagged, so the raw NUL
# stream is parsed exactly once.
# Pathspec note: git's default wildmatch lets '*' cross '/', so 'k8s/*.yaml'
# matches k8s yaml at EVERY depth — including direct children of k8s/, which
# 'k8s/**/*.yaml' (requiring two path separators) silently missed.
scan() {
  git grep -z -nI $CACHED -E "$PATTERN" ${REF:+"$REF"} -- 'k8s/*.yaml' 'k8s/*.yml' \
  | awk -v RS='\n' -v strip="$strip" '
    {
      n = index($0, "\0"); if (n == 0) next
      path = substr($0, 1, n - 1); rest = substr($0, n + 1)
      m = index(rest, "\0"); if (m == 0) next
      lineno = substr(rest, 1, m - 1); content = substr(rest, m + 1)
      if (strip > 0) path = substr(path, strip + 1)
      code = content; sub(/#.*$/, "", code)
      if (code !~ /<[A-Z][A-Z0-9_]*>/) next
      print "HIT\t" path ":" lineno ":" content
      while (match(code, /<[A-Z][A-Z0-9_]*>/)) {
        print "PH\t" path ":" substr(code, RSTART, RLENGTH)
        code = substr(code, RSTART + RLENGTH)
      }
    }'
}

# git grep exits 1 for "no matches" (benign) but >1 for real failures (bad
# pathspec, repo errors). A bare `|| true` here once turned those failures into
# a false "ready to bootstrap" — distinguish them.
set +e
scanned=$(scan)
rc=$?
set -e
if (( rc > 1 )); then
  echo "check-placeholders: git grep failed (exit $rc)" >&2
  exit 2
fi
# $'\t' (not a sed \t escape): BSD/macOS sed treats \t as literal 't', which
# silently emptied these matches on macOS.
hits=$(printf '%s\n' "$scanned" | sed -n $'s/^HIT\t//p')

if [[ "$MODE" == expect-filled ]]; then
  if [[ -n "${hits//[[:space:]]/}" ]]; then
    echo "Unfilled placeholders in ${SCOPE}:" >&2
    printf '%s\n' "$hits" >&2
    echo >&2
    echo "Fill them per docs/install.md §9, then commit and push." >&2
    exit 1
  fi
  echo "check-placeholders: none left in ${SCOPE} — ready to bootstrap."
  exit 0
fi

# expect-template: the set present must be exactly the set §9 documents.
# Taken from the PH records, whose path came from the NUL-delimited field rather
# than a colon split of content.
found=$(printf '%s\n' "$scanned" | sed -n $'s/^PH\t//p' | sort)

if diff <(printf '%s\n' "$EXPECTED" | sort) <(printf '%s\n' "$found") >/dev/null; then
  echo "check-placeholders: template intact in ${SCOPE} (9 placeholders)."
  exit 0
fi

echo "Placeholder set in ${SCOPE} does not match docs/install.md §9." >&2
echo "  '<' = expected but MISSING (deleted, or a real value committed over it)" >&2
echo "  '>' = present but UNEXPECTED (new placeholder — add it to EXPECTED here" >&2
echo "        and to the §9 table)" >&2
echo >&2
diff <(printf '%s\n' "$EXPECTED" | sort) <(printf '%s\n' "$found") >&2 || true
exit 1
