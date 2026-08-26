// =============================================================================
// main.bicep — orchestrator for the "webservices-v2" cluster deployment.
//
// Deploys the AKS cluster (aks.bicep). Cluster shape lives in the COMMITTED
// infra/env/webservices.bicepparam (no secrets, no subscription IDs — this is
// a public repo; the subscription is selected out-of-band via `az account set`).
// =============================================================================

@description('Cluster name')
param clusterName string = 'webservices-v2'

@description('Azure region. Sweden Central.')
param location string = 'swedencentral'

@description('Kubernetes MINOR version alias (no patch — see aks.bicep).')
param kubernetesVersion string = '1.36'

@description('SLA tier (Free = no paid API-server SLA).')
@allowed(['Free', 'Standard'])
param skuTier string = 'Free'

@description('Node pool VM size. D4s_v6 = Intel, 4 vCPU / 16 GB, 12 attachable data disks.')
param vmSize string = 'Standard_D4s_v6'

@description('Node count (manual scaling).')
param nodeCount int = 1

@description('Availability zone — ONE. Azure disks cannot cross zones; see docs/decisions.md entry 15.')
param zones string[] = ['1']

@description('Durable Log Analytics workspace receiving API-server audit logs. Must exist before this deploys — docs/install.md §5b.')
param auditWorkspaceName string

@description('Resource group holding the audit workspace (the long-lived infra RG, not the cluster RG).')
param auditWorkspaceResourceGroup string

module aks 'aks.bicep' = {
  name: 'aks'
  params: {
    clusterName: clusterName
    location: location
    kubernetesVersion: kubernetesVersion
    skuTier: skuTier
    vmSize: vmSize
    nodeCount: nodeCount
    zones: zones
    auditWorkspaceName: auditWorkspaceName
    auditWorkspaceResourceGroup: auditWorkspaceResourceGroup
  }
}

// The durable Key Vault and backup storage are NOT part of this deployment:
// they live in the long-lived infra RG (keyvault.bicep / backup-storage.bicep,
// deployed standalone) so they survive cluster teardown.

output oidcIssuerUrl string = aks.outputs.oidcIssuerUrl
output kubeletIdentityObjectId string = aks.outputs.kubeletIdentityObjectId
output clusterName string = aks.outputs.clusterName
output clusterFqdn string = aks.outputs.clusterFqdn
