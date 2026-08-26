// =============================================================================
// Params for the "webservices-v2" AKS cluster.
//
// This file is committed — it holds no secrets, only cluster shape. The Azure
// subscription is selected out-of-band (`az account set`) / by the target
// resource group, so no subscription ID lives here. Edit these values to
// change the cluster, then:
//   az deployment group create -g <rg> -f infra/main.bicep -p infra/env/webservices.bicepparam
// =============================================================================
using '../main.bicep'

param clusterName = 'webservices-v2'
param location = 'swedencentral'

// --- Budget-tuned defaults ---
param kubernetesVersion = '1.36'  // minor alias only — the patch channel owns the patch level
param skuTier = 'Free'          // 'Free' = no paid API-server SLA (budget). 'Standard' to buy the SLA.
param vmSize = 'Standard_D4s_v6' // Intel, 4 vCPU / 16 GB, 12 data disks — disks are the binding limit.
param nodeCount = 1              // Manual scaling: bump this + redeploy to add nodes.
param zones = ['1']              // ONE zone — disks cannot cross zones (decisions.md 15).

// --- Audit logging (docs/decisions.md 9) ---
param auditWorkspaceName = 'log-webservices'
param auditWorkspaceResourceGroup = 'webservices-infra'
