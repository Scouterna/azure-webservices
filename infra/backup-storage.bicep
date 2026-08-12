// =============================================================================
// backup-storage.bicep — durable Azure Blob storage for cluster backups.
//
// Deployed to the SEPARATE, long-lived resource group (webservices-infra),
// NOT the cluster RG — so backups survive cluster teardown/loss. This breaks
// the circular dependency of backing up to the in-cluster MinIO (single node).
// Velero writes namespace/state backups here; CloudNativePG can also target it
// for Postgres Barman backups.
//
// Network exposure is an ACCEPTED RISK — the endpoint is reachable from any
// network. Rationale and what would close it: docs/maintenance.md.
//
// Deploy:
//   az deployment group create -g webservices-infra \
//     -f infra/backup-storage.bicep -p storageAccountName=<name>
// =============================================================================

@description('Storage account name (globally unique, 3-24 chars, lowercase alphanumeric).')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Azure region.')
param location string = resourceGroup().location

@description('Blob container for Velero backups.')
param veleroContainerName string = 'velero'

@description('Blob container for the shared Postgres server\'s Barman backups.')
param cnpgSharedContainerName string = 'cnpg-shared'

@description('Blob soft-delete retention (days) — recover accidentally/maliciously deleted backups.')
param blobSoftDeleteDays int = 30

@description('Resource tags.')
param tags object = {
  ManagedBy: 'Bicep'
  Initiative: 'webservices-cluster'
  Purpose: 'backups'
}

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_ZRS' // zone-redundant (survives a zone/datacenter failure). Standard_LRS is cheaper; GRS for regional DR.
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Cool' // backups are written-often, read-rarely — Cool tier is cheaper.
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false // never expose backups publicly.
    // Velero uses Workload Identity (no keys); CloudNativePG's Barman Cloud
    // Plugin uses a storage-account key (via ESO from Key Vault), so shared-key
    // access is enabled.
    allowSharedKeyAccess: true
    // Open by design — see the header note before changing.
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: storage
  name: 'default'
  properties: {
    // Soft-delete so a deleted backup blob is recoverable.
    deleteRetentionPolicy: {
      enabled: true
      days: blobSoftDeleteDays
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: blobSoftDeleteDays
    }
  }
}

resource veleroContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobService
  name: veleroContainerName
  properties: {
    publicAccess: 'None'
  }
}

// Declared here (not an imperative doc step) so a rebuild cannot skip it —
// without this container the shared Cluster comes up but ContinuousArchiving
// silently never goes True. Per-project escape-hatch containers (cnpg-<project>)
// stay with scripts/onboard-cnpg-backup.sh.
resource cnpgSharedContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobService
  name: cnpgSharedContainerName
  properties: {
    publicAccess: 'None'
  }
}

@description('Storage account resource ID — for role assignments (Storage Blob Data Contributor to Velero).')
output storageAccountId string = storage.id
output storageAccountName string = storage.name
@description('Blob endpoint.')
output blobEndpoint string = storage.properties.primaryEndpoints.blob
output veleroContainerName string = veleroContainerName
