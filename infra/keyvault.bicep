// =============================================================================
// keyvault.bicep — durable Key Vault for centralized secrets.
//
// Deployed to a SEPARATE, long-lived resource group (e.g. webservices-infra),
// NOT the cluster RG — so it survives cluster teardown/rebuild. The cluster's
// External Secrets Operator federates to this vault via Workload Identity.
//
// Network exposure is an ACCEPTED RISK — the vault endpoint is reachable from
// any network. This vault is the cluster's root of trust, so the entry in
// docs/maintenance.md ("Accepted risks") is worth reading before changing it.
//
// Deploy:
//   az deployment group create -g webservices-infra \
//     -f infra/keyvault.bicep -p keyVaultName=<name>
// =============================================================================

@description('Key Vault name (globally unique, 3-24 chars, alphanumeric + hyphens).')
@minLength(3)
@maxLength(24)
param keyVaultName string

@description('Azure region.')
param location string = resourceGroup().location

@description('Enable purge protection (cannot be turned off once on; blocks permanent deletion for 90 days).')
param enablePurgeProtection bool = true

@description('Resource tags.')
param tags object = {
  ManagedBy: 'Bicep'
  Initiative: 'webservices-cluster'
  Purpose: 'centralized-secrets'
}

resource vault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    // Azure RBAC authorization (not legacy access policies) — grant identities
    // roles like 'Key Vault Secrets User' instead of per-vault access policies.
    enableRbacAuthorization: true
    // Soft-delete is always on; purge protection makes deletion recoverable-only.
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: enablePurgeProtection ? true : null
    // Open by design — see the header note before changing.
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

@description('Key Vault resource ID.')
output vaultId string = vault.id
@description('Key Vault URI (https://<name>.vault.azure.net/) — used by ESO SecretStore.')
output vaultUri string = vault.properties.vaultUri
output vaultName string = vault.name
