#!/usr/bin/env bash
# Backup container for a project that runs its OWN CloudNativePG instance.
#
# NOT needed for the normal path: a database on the shared Postgres server is
# backed up with the whole server, into the `cnpg-shared` container. Use this
# only for the escape hatch — a project with its own Cluster in its own
# namespace (see docs/postgres.md).
#
# Creates container `cnpg-<project>` in the durable backup storage account.
#
# TWO DIFFERENT IDENTITIES are involved — do not conflate them:
#
#   1. CREATING the container (this script) uses YOUR OWN Azure login
#      (`--auth-mode login`, i.e. AAD), not a key. You need a role granting
#      container create on the storage account — `Storage Blob Data Contributor`
#      on it (or on the resource group) is enough. A plain `Contributor` role
#      assignment on the subscription does NOT include data-plane actions, and
#      fails here with AuthorizationPermissionMismatch.
#
#   2. CNPG WRITING backups later uses the STORAGE-ACCOUNT KEY, which ESO
#      materializes in the project's namespace from Key Vault. That is the
#      `storageKey` in the ObjectStore, and it is a separate credential from the
#      login above.
#
# (Workload Identity for CNPG backups is a future improvement; the plugin's
# Managed-Identity path is currently finicky with multiple node identities.
# Velero already uses Workload Identity — CNPG is the outlier here.)
#
# Usage:
#   scripts/onboard-cnpg-backup.sh <project>
set -euo pipefail

PROJECT="${1:?project name required}"

# --- Environment (adjust to your deployment) ---
# INFRA_RG is for the operator's benefit only — it is echoed below so it is clear
# which resource group to look in. It is deliberately NOT passed to the az call:
# storage account names are globally unique, and `--resource-group` is deprecated
# on `az storage container create`.
INFRA_RG="webservices-infra"
STORAGE_ACCOUNT="stwsv2backup"
CONTAINER="cnpg-${PROJECT}"

# The project name becomes both a Kubernetes namespace and this container name.
# Validate rather than normalise: silently lowercasing would create a container
# whose name no longer matches the project's namespace, which is harder to spot
# later than a refusal now.
#
# Azure is STRICTER than RFC 1123 on one point: every hyphen must sit between
# two alphanumerics, so consecutive hyphens are rejected. `foo--bar` is a legal
# namespace that Azure refuses, so this check is not the namespace rule.
# Length: container names max at 63 and ours carries a 'cnpg-' prefix, hence 58.
# (Azure's 3-char minimum needs no check — the prefix alone is 5.)
if ! [[ "$PROJECT" =~ ^[a-z0-9]([a-z0-9]|-[a-z0-9])*$ ]]; then
  echo "error: project name '$PROJECT' is not valid." >&2
  echo "       Use lowercase letters, digits and single hyphens; start and end" >&2
  echo "       alphanumeric. Consecutive hyphens are rejected by Azure even" >&2
  echo "       though Kubernetes allows them in a namespace." >&2
  exit 1
fi
if (( ${#PROJECT} > 58 )); then
  echo "error: project name '$PROJECT' is ${#PROJECT} chars; max 58." >&2
  echo "       The container name 'cnpg-<project>' must fit Azure's 63-char limit." >&2
  exit 1
fi

echo "==> container ${CONTAINER} in ${STORAGE_ACCOUNT} (resource group ${INFRA_RG})"
# --auth-mode login = the operator's AAD identity (see the header). Deliberately
# NOT --account-key: creating a container is a one-off admin action, and passing
# the key here would put a long-lived credential on the command line and into
# shell history for no benefit. The key's only consumer is CNPG, via ESO.
az storage container create --account-name "$STORAGE_ACCOUNT" --auth-mode login \
  --name "$CONTAINER" >/dev/null

echo ""
echo "Container ready. Next:"
echo "  1. Ensure the storage account key is in Key Vault (secret"
echo "     'backup-storage-account-key'); ESO materializes it in the namespace."
echo "  2. In the project's manifests (copy the reference example):"
echo "       ObjectStore.spec.configuration.destinationPath:"
echo "         https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}"
echo "  3. Reference the plugin in Cluster.spec.plugins and add a ScheduledBackup."
