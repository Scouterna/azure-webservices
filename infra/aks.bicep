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
//   - Single node pool (mode System) runs everything. Add a node by bumping
//     `nodeCount` and redeploying; add a dedicated user pool later if needed.
//   - Autoscaling is OFF on purpose: scaling is a reviewed parameter change.
//
// Deploy (subscription is selected out-of-band via `az account set` / the RG;
// no subscription ID lives in this repo):
//   az deployment group create -g <rg> \
//     -f infra/aks.bicep -p infra/env/webservices.bicepparam
// =============================================================================

@description('Cluster name. webservices-v2')
param clusterName string = 'webservices-v2'

@description('Azure region. Sweden Central.')
param location string = 'swedencentral'

@description('Kubernetes MINOR version alias (no patch): autoUpgradeProfile patches the cluster, so a pinned patch version would make a later redeploy (the nodeCount workflow) submit a downgrade and be rejected.')
param kubernetesVersion string = '1.36'

@description('DNS prefix for the managed cluster API server.')
param dnsPrefix string = clusterName

@description('Availability zones to place the node pool across.')
param zones string[] = ['1', '2', '3']

@description('VM size for the node pool. D4s_v6 (Intel, 4 vCPU / 16 GB, 12 attachable data disks)')
param vmSize string = 'Standard_D4s_v6'

@description('Node count. MANUAL scaling — bump this and redeploy to add nodes (no autoscaler).')
param nodeCount int = 1

@description('Managed OS disk size (GB). 128 = the AKS default.')
param osDiskSizeGB int = 128

@description('Disable the static cluster-admin certificate (`az aks get-credentials --admin`). Committed as true; a fresh build must enable it for bootstrap and turn it back off — docs/install.md §7b and §12.')
param disableLocalAccounts bool = true

@description('SLA tier. Free = no SLA')
@allowed(['Free', 'Standard'])
param skuTier string = 'Free'

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

    // Break-glass is `az aks update --enable-local-accounts` — an Azure operation
    // that shows up in the Activity Log, unlike using the cert. docs/security.md §4.
    disableLocalAccounts: disableLocalAccounts

    // OIDC issuer + Workload Identity — credential-free pod access to Azure resources
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }

    // Keep the cluster patched automatically.
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

    // Single node pool (mode System) — VMSS, zonal, MANUAL scaling.
    // Add a dedicated user pool later if load demands it
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

// ---- Outputs (for follow-up: federated identity setup, ACR pull, kubeconfig) ----
@description('OIDC issuer URL — bind External Secrets Operator federated identity credential to this (Phase 2).')
output oidcIssuerUrl string = aks.properties.oidcIssuerProfile.issuerURL

@description('Cluster managed-identity principal ID — for RBAC assignments.')
output clusterIdentityPrincipalId string = aks.identity.principalId

@description('Kubelet identity object ID — for optional ACR pull / Key Vault access grants.')
output kubeletIdentityObjectId string = aks.properties.identityProfile.kubeletidentity.objectId

output clusterName string = aks.name
output clusterFqdn string = aks.properties.fqdn
