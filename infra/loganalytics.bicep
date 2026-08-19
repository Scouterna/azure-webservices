// =============================================================================
// loganalytics.bicep — durable Log Analytics workspace for API-server audit logs.
//
// Deployed to the SEPARATE, long-lived resource group (webservices-infra), NOT the
// cluster RG — audit logs whose only purpose is answering "what happened" must
// outlive the cluster they describe, including a teardown that is itself the thing
// under investigation.
//
// What is collected, what is not, the cost, and who can read it:
// docs/decisions.md entry 9.
//
// Deploy:
//   az deployment group create -g webservices-infra \
//     -f infra/loganalytics.bicep -p workspaceName=<name>
// =============================================================================

@description('Workspace name (4-63 chars, alphanumeric + hyphens, must not start/end with a hyphen).')
@minLength(4)
@maxLength(63)
param workspaceName string

@description('Azure region.')
param location string = resourceGroup().location

@description('Interactive retention in days. docs/decisions.md 9.')
@minValue(30)
@maxValue(730)
param retentionInDays int = 30

@description('Hard daily ingestion cap in GB; -1 disables it. Hitting it stops ingestion for the rest of the UTC day — docs/decisions.md 9.')
@minValue(-1)
param dailyQuotaGb int = 1

@description('Resource tags.')
param tags object = {
  ManagedBy: 'Bicep'
  Initiative: 'webservices-cluster'
  Purpose: 'audit-logs'
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    workspaceCapping: {
      dailyQuotaGb: dailyQuotaGb
    }
    features: {
      // false = querying requires a grant on THIS workspace. Left off deliberately:
      // with resource-context, read on the cluster is enough. docs/decisions.md 9.
      enableLogAccessUsingOnlyResourcePermissions: false
      // Close the legacy shared-key ingestion path; nothing here uses it.
      disableLocalAuth: true
    }
  }
}

@description('ARM resource ID — this is what a diagnostic setting targets.')
output workspaceId string = workspace.id

@description('Workspace name, as passed in.')
output workspaceName string = workspace.name

@description('Workspace GUID — this is what `az monitor log-analytics query --workspace` wants, NOT workspaceId.')
output customerId string = workspace.properties.customerId
