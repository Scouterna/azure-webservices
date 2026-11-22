// =============================================================================
// "webservices-v2" AKS cluster — shared Scouterna Kubernetes cluster
// -----------------------------------------------------------------------------
// A purpose-built, portable-by-intent foundation:
//   1. networkPlugin: azure + overlay   -> modern CNI (no deprecated kubenet)
//   2. networkDataplane: cilium         -> eBPF dataplane + Cilium NetworkPolicy
//   3. ipFamilies: IPv4 + IPv6          -> dual-stack (IMMUTABLE, see networkProfile)
//   4. VMSS node pool + manual scaling   -> deliberate scale-up, no surprises
//   5. SystemAssigned identity + OIDC + Workload Identity -> credential-free
//   (+ availabilityZones                 -> zonal placement)
//
// Budget notes:
//   - The `system` pool runs the platform and production. Add a node by
//     bumping `nodeCount` and redeploying.
//   - Autoscaling is OFF there on purpose: scaling is a reviewed parameter change.
//   - The `spot` pool is for dev/staging that opt in. It autoscales only to
//     replace an evicted node, up to `spotMaxCount`. docs/decisions.md entry 32.
//
// Deploy (subscription is selected out-of-band via `az account set` / the RG;
// no subscription ID lives in this repo):
//   az deployment group create -g <rg> \
//     -f infra/main.bicep -p infra/env/webservices.bicepparam
// (main.bicep is the entry point; the bicepparam declares `using '../main.bicep'`.)
// =============================================================================

@description('Cluster name. webservices-v2')
param clusterName string = 'webservices-v2'

@description('Azure region. Sweden Central.')
param location string = 'swedencentral'

@description('Kubernetes MINOR version alias (no patch): autoUpgradeProfile patches the cluster, so a pinned patch version would make a later redeploy (the nodeCount workflow) submit a downgrade and be rejected.')
param kubernetesVersion string = '1.36'

@description('DNS prefix for the managed cluster API server.')
param dnsPrefix string = clusterName

@description('Availability zone for the node pool. ONE zone — Azure disks cannot cross zones, so a multi-zone pool makes node replacement destructive. docs/decisions.md entry 15.')
param zones string[] = ['1']

@description('VM size for the node pool. D4s_v6 (Intel, 4 vCPU / 16 GB, 12 attachable data disks)')
param vmSize string = 'Standard_D4s_v6'

@description('Node count. MANUAL scaling — bump this and redeploy to add nodes (no autoscaler).')
param nodeCount int = 1

@description('VM size for the spot pool (dev/staging only). docs/decisions.md entry 32.')
param spotVmSize string = 'Standard_D2s_v6'

@description('Spot pool ceiling. The autoscaler only replaces evicted nodes up to this; raising it is a reviewed change.')
param spotMaxCount int = 1

@description('Managed OS disk size (GB). 128 = the AKS default.')
param osDiskSizeGB int = 128

@description('SLA tier. Free = no SLA')
@allowed(['Free', 'Standard'])
param skuTier string = 'Free'

@description('Name of the durable Log Analytics workspace that receives API-server audit logs (infra/loganalytics.bicep). It must already exist — docs/install.md §5b.')
param auditWorkspaceName string

@description('Resource group holding that workspace. Separate from the cluster RG so audit logs survive a teardown.')
param auditWorkspaceResourceGroup string

@description('Resource tags.')
param tags object = {
  Environment: 'Shared'
  ManagedBy: 'Bicep'
  Initiative: 'webservices-cluster'
}

resource aks 'Microsoft.ContainerService/managedClusters@2026-03-01' = {
  name: clusterName
  location: location
  tags: tags

  // Modern identity — System-assigned managed identity, not a Service Principal.
  identity: {
    type: 'SystemAssigned'
  }

  sku: {
    name: 'Base'
    tier: skuTier
  }

  properties: {
    kubernetesVersion: kubernetesVersion
    dnsPrefix: dnsPrefix
    enableRBAC: true

    // OIDC issuer + Workload Identity — credential-free pod access to Azure resources
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }

    // Keep the cluster patched automatically, in upgradeWindow (below).
    autoUpgradeProfile: {
      upgradeChannel: 'patch'
      nodeOSUpgradeChannel: 'NodeImage'
    }

    // Network: Azure CNI overlay + Cilium dataplane & policy, dual-stack.
    // ipFamilies and the CIDRs are immutable — set at creation only; changing
    // them means a rebuild. The v6 ULA prefix is randomly generated per RFC 4193;
    // don't replace it with a tidier-looking value.
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkDataplane: 'cilium'
      networkPolicy: 'cilium'
      loadBalancerSku: 'standard'
      outboundType: 'loadBalancer'
      ipFamilies: ['IPv4', 'IPv6']
      podCidrs: ['10.244.0.0/16', 'fdbc:2e46:9934:1::/64']
      serviceCidrs: ['10.0.0.0/16', 'fdbc:2e46:9934:2::/108']
      dnsServiceIP: '10.0.0.10' // must fall inside the first serviceCidrs entry
      // countIPv6 defaults to 0. Undeclared, a redeploy silently drops the v6
      // outbound IP and IPv6 egress with it. docs/decisions.md entry 10.
      loadBalancerProfile: {
        managedOutboundIPs: {
          count: 1
          countIPv6: 1
        }
      }
    }

    // Key Vault CSI addon — kept available as an opt-in escape hatch for
    // projects that specifically want CSI. External Secrets Operator is the
    // sanctioned secrets path (see README).
    addonProfiles: {
      azureKeyvaultSecretsProvider: {
        enabled: true
        config: {
          enableSecretRotation: 'true'
        }
      }
    }

    // `system` only: platform + production, MANUAL scaling. The `spot` pool is a
    // child resource below — AKS rejects a new pool added through this array.
    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        type: 'VirtualMachineScaleSets'
        vmSize: vmSize
        osType: 'Linux'
        osSKU: 'AzureLinux'
        osDiskType: 'Managed'
        osDiskSizeGB: osDiskSizeGB
        availabilityZones: zones
        enableAutoScaling: false
        count: nodeCount
        maxPods: 110
        upgradeSettings: {
          maxSurge: '33%'
        }
      }
    ]
  }
}

// `spot`: opt-in dev/staging, same zone as `system` (entry 15). A child resource,
// not in agentPoolProfiles: AKS refuses to add a pool to an existing cluster that
// way. AKS labels and taints it kubernetes.azure.com/scalesetpriority=spot:NoSchedule;
// pods opt in with a toleration + required node affinity (docs/onboarding.md).
resource spotPool 'Microsoft.ContainerService/managedClusters/agentPools@2026-03-01' = {
  parent: aks
  name: 'spot'
  properties: {
    mode: 'User'
    type: 'VirtualMachineScaleSets'
    vmSize: spotVmSize
    osType: 'Linux'
    osSKU: 'AzureLinux'
    osDiskType: 'Managed'
    osDiskSizeGB: osDiskSizeGB
    availabilityZones: zones
    scaleSetPriority: 'Spot'
    scaleSetEvictionPolicy: 'Delete'
    spotMaxPrice: -1 // evicted for capacity only, never for price
    // Autoscaler exists only to bring an evicted node back; min 0 = no cost when unused.
    enableAutoScaling: true
    minCount: 0
    maxCount: spotMaxCount
    maxPods: 30 // smaller per-pod kubelet memory reserve than 110 on an 8 GB VM
  }
}

// Both upgrade channels start only in this weekly early-morning slot: with one
// node, every upgrade is two short full outages. Tuesday 03:00 UTC for 4h (AKS's
// minimum), after the 02:00–02:30 UTC backups. docs/decisions.md entry 16.
var upgradeWindow = {
  schedule: {
    weekly: {
      intervalWeeks: 1
      dayOfWeek: 'Tuesday'
    }
  }
  durationHours: 4
  startTime: '03:00'
  utcOffset: '+00:00'
}

resource nodeOSUpgradeWindow 'Microsoft.ContainerService/managedClusters/maintenanceConfigurations@2026-03-01' = {
  parent: aks
  name: 'aksManagedNodeOSUpgradeSchedule'
  properties: {
    maintenanceWindow: upgradeWindow
  }
}

resource patchUpgradeWindow 'Microsoft.ContainerService/managedClusters/maintenanceConfigurations@2026-03-01' = {
  parent: aks
  name: 'aksManagedAutoUpgradeSchedule'
  properties: {
    maintenanceWindow: upgradeWindow
  }
}

// Ship API-server audit logs off the cluster. kube-audit-admin only, and no
// `guard` (it audits Entra RBAC, which this cluster does not use). docs/decisions.md 9.
resource auditWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: auditWorkspaceName
  scope: resourceGroup(auditWorkspaceResourceGroup)
}

resource auditDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'audit-to-log-analytics'
  scope: aks
  properties: {
    workspaceId: auditWorkspace.id
    // Dedicated = the AKSAuditAdmin table. Default lands rows in AzureDiagnostics,
    // where the queries in install.md §11 find nothing. docs/decisions.md 9.
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        category: 'kube-audit-admin'
        enabled: true
      }
    ]
  }
}

// ---- Outputs (for follow-up: federated identity setup, ACR pull, kubeconfig) ----
@description('OIDC issuer URL — bind External Secrets Operator federated identity credential to this (Phase 2).')
output oidcIssuerUrl string = aks.properties.oidcIssuerProfile.issuerURL

@description('Cluster managed-identity principal ID — for RBAC assignments.')
output clusterIdentityPrincipalId string = aks.identity.principalId

@description('Kubelet identity object ID — for optional ACR pull / Key Vault access grants.')
output kubeletIdentityObjectId string = aks.properties.identityProfile.kubeletidentity.objectId

output clusterName string = aks.name
output clusterFqdn string = aks.properties.fqdn
