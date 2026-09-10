@description('Azure region for all resources. Must be a Discovery-supported region.')
@allowed([
  'eastus'
  'swedencentral'
  'uksouth'
])
param location string = 'swedencentral'

@description('Name of the Microsoft Discovery Supercomputer. Must be 3-24 characters, alphanumeric and hyphens only.')
@minLength(3)
@maxLength(24)
param supercomputerName string = 'sc-${uniqueString(resourceGroup().id)}'

@description('Name of the Node Pool created under the Supercomputer. Must be 1-12 lowercase alphanumeric characters, starting with a letter.')
@minLength(1)
@maxLength(12)
param nodePoolName string = 'nodepool1'

@description('Name of the Microsoft Discovery Workspace. Must be 3-24 characters, alphanumeric and hyphens only.')
@minLength(3)
@maxLength(24)
param workspaceName string = 'ws-${uniqueString(resourceGroup().id)}'

@description('Name of the Chat Model Deployment created under the Workspace.')
@minLength(3)
@maxLength(24)
param chatModelDeploymentName string = 'gpt-5-4'

@description('Name of the Microsoft Discovery Storage Container resource. Must be 3-24 characters, alphanumeric and hyphens only.')
@minLength(3)
@maxLength(24)
param storageContainerName string = 'stc-${uniqueString(resourceGroup().id)}'

@description('Name of the Project created under the Workspace. Must be 3-24 characters, alphanumeric and hyphens only.')
@minLength(3)
@maxLength(24)
param projectName string = 'prj-${uniqueString(resourceGroup().id)}'

@description('Name of the Virtual Network. Must be 2-64 characters: letters, numbers, underscores, periods, or hyphens; must start with a letter or number and end with a letter, number, or underscore.')
@minLength(2)
@maxLength(64)
param vnetName string = 'discovery-vnet'

@description('Name of the User-Assigned Managed Identity.')
param managedIdentityName string = 'uami-${uniqueString(resourceGroup().id)}'

@description('Globally unique name of the Azure Storage Account (3-24 lowercase alphanumeric characters).')
@minLength(3)
@maxLength(24)
param storageAccountName string = 'stg${uniqueString(resourceGroup().id)}'

@description('Name of the blob container inside the Storage Account used for Discovery outputs.')
param blobContainerName string = 'discoveryoutputs'

@description('Replication SKU for the Storage Account. Zone/geo-redundant options are recommended over locally-redundant storage for resiliency.')
@allowed([
  'Standard_ZRS'
  'Standard_GRS'
  'Standard_GZRS'
  'Standard_RAGRS'
  'Standard_RAGZRS'
])
param storageAccountSku string = 'Standard_GRS'

@description('Address space for the Virtual Network.')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('Address prefix for the Supercomputer Node Pool subnet.')
param supercomputerNodepoolSubnetPrefix string = '10.0.1.0/24'

@description('Address prefix for the AKS system subnet used by the Supercomputer.')
param aksSubnetPrefix string = '10.0.2.0/24'

@description('Address prefix for the Workspace subnet (delegated to Microsoft.App/environments).')
param workspaceSubnetPrefix string = '10.0.3.0/24'

@description('Address prefix for the Private Endpoint subnet.')
param privateEndpointSubnetPrefix string = '10.0.4.0/24'

@description('Address prefix for the Agent subnet.')
param agentSubnetPrefix string = '10.0.5.0/24'

@description('Address prefix for Search Subnet.')
param searchSubnetPrefix string = '10.0.6.0/24'

@description('VM SKU for the Node Pool.')
param nodePoolVmSize string = 'Standard_D4s_v6'

@description('Maximum number of nodes in the Node Pool.')
@minValue(1)
param nodePoolMaxNodeCount int = 3

@description('Minimum number of nodes in the Node Pool (0 allows scale-to-zero).')
@minValue(0)
param nodePoolMinNodeCount int = 0

@description('Scale set priority for the Node Pool.')
@allowed([
  'Regular'
  'Spot'
])
param nodePoolScaleSetPriority string = 'Regular'

@description('Chat model format.')
param chatModelFormat string = 'OpenAI'

@description('Chat model name to deploy.')
param chatModelName string = 'gpt-5.4'

@description('Enable GitHub Copilot and AI features in the Discovery workspace via the discovery.workbench.enableGhcpAiFeatures tag.')
param enableGhcpAiFeatures bool = true

@description('Enable the VS Code Extension Marketplace in the Discovery workspace via the discovery.workbench.enableExtensions tag.')
param enableExtensions bool = true

@description('Workspace network isolation mode via the NetworkIsolation tag. Set to false to enable public preview access as documented in the Infrastructure portal quickstart.')
param networkIsolation bool = true

// -----------------------------------------------------------------------------
// Discovery control-plane first-party service principal.
//
// Discovery workspaces / bookshelves / supercomputers are network-hardened by
// default and require the control-plane app to configure a Network Security
// Perimeter (NSP) in your subscription. The app cannot do that unless it holds
// both the custom "Discovery NSP Perimeter Joiner" role and the built-in
// "Reader" role at subscription scope.
//
// Docs:
//   https://learn.microsoft.com/en-us/azure/microsoft-discovery/quickstart-infrastructure-portal#b-assign-required-roles-to-discovery-control-plane-service-app
//   https://learn.microsoft.com/en-us/azure/microsoft-discovery/how-to-configure-network-security?tabs=azure-cli
//
// The Application (client) ID of the first-party app is fixed:
//   92c174ac-8e41-4815-a1b7-d81b19ab03ce
// but role assignments require the Object ID (the service principal's id in
// the current tenant). Look it up before deploying:
//   az ad sp show --id 92c174ac-8e41-4815-a1b7-d81b19ab03ce --query id -o tsv
// -----------------------------------------------------------------------------
@description('Object ID (not App ID) of the Discovery control-plane first-party service principal in the current tenant. Resolve with: az ad sp show --id 92c174ac-8e41-4815-a1b7-d81b19ab03ce --query id -o tsv')
param discoveryControlPlanePrincipalId string

// -----------------------------------------------------------------------------
// Discovery Studio (data-plane) administrators.
//
// The Microsoft Discovery workspace ships with its OWN data-plane RBAC that is
// completely separate from ARM Owner / Contributor. Without a Discovery-scoped
// role, users signing in to https://studio.discovery.microsoft.com see
// "Access denied. Ensure you have the correct role assigned on this workspace
// resource in the Azure portal." when trying to create Agents/Projects — even
// when they hold Owner on the subscription.
//
// This template assigns "Microsoft Discovery Platform Administrator (Preview)"
// (roleId 7a2b6e6c-472e-4b39-8878-a26eb63d75c6) at the resource group scope,
// which grants Microsoft.Discovery/* on all Discovery resources in the RG
// (workspaces, storageContainers, supercomputers, and their children).
//
// Pass one or more Entra Object IDs; typically populated from
//   az ad signed-in-user show --query id -o tsv
// by the deploy wrapper script.
// -----------------------------------------------------------------------------
@description('Object IDs of Entra principals to grant "Microsoft Discovery Platform Administrator (Preview)" on this resource group. Enables Discovery Studio operations (create Agents/Projects/etc.). Leave empty to skip.')
param workspaceAdminPrincipalIds array = []

@description('Principal type for workspaceAdminPrincipalIds. Use User for individual accounts, Group for Entra security groups, ServicePrincipal for apps.')
@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
param workspaceAdminPrincipalType string = 'User'

// Built-in role definition IDs
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var discoveryPlatformContributorRoleId = '01288891-85ee-45a7-b367-9db3b752fc65'
var discoveryPlatformAdministratorRoleId = '7a2b6e6c-472e-4b39-8878-a26eb63d75c6'
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

// Subscription-scoped module: create the "Discovery NSP Perimeter Joiner"
// custom role and grant NSP Perimeter Joiner + Reader to the Discovery
// control-plane service principal. This must complete before any
// Microsoft.Discovery/* resource is created, otherwise the control plane
// fails to provision the auto-generated NetworkSecurityPerimeter and the
// deployment returns InternalServerError from the NSP resource.
// Deployment name includes the region so this template can be redeployed
// in different regions of the same subscription without hitting the
// "InvalidDeploymentLocation" error (subscription-scope deployments are
// locked to a single location per deployment name). All underlying
// resources are GUID-based and idempotent.
module discoveryControlPlaneRoles 'subscription-roles.bicep' = {
  name: 'discoveryControlPlaneRoles-${location}'
  scope: subscription()
  params: {
    discoveryControlPlanePrincipalId: discoveryControlPlanePrincipalId
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'supercomputerNodepoolSubnet'
        properties: {
          addressPrefix: supercomputerNodepoolSubnetPrefix
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
            }
          ]
        }
      }
      {
        name: 'aksSubnet'
        properties: {
          addressPrefix: aksSubnetPrefix
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
            }
          ]
        }
      }
      {
        name: 'workspaceSubnet'
        properties: {
          addressPrefix: workspaceSubnetPrefix
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
            }
          ]
        }
      }
      {
        name: 'privateEndpointSubnet'
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
        }
      }
      {
        name: 'agentSubnet'
        properties: {
          addressPrefix: agentSubnetPrefix
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
            }
          ]
        }
      }
      {
        name: 'searchSubnet'
        properties: {
          addressPrefix: searchSubnetPrefix
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
            }
          ]
        }
      }
    ]
  }
}

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: managedIdentityName
  location: location
  properties: {
    isolationScope: 'Regional'
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: storageAccountSku
  }
  dependsOn: [
    vnet
  ]
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    // NOTE: defaultAction is intentionally 'Allow'. 
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
      virtualNetworkRules: [
        {
          id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'supercomputerNodepoolSubnet')
          action: 'Allow'
        }
        {
          id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'aksSubnet')
          action: 'Allow'
        }
        {
          id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'workspaceSubnet')
          action: 'Allow'
        }
        {
          id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'agentSubnet')
          action: 'Allow'
        }
        {
          id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'searchSubnet')
          action: 'Allow'
        }
      ]
    }
  }
}

resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    cors: {
      corsRules: [
        {
          allowedOrigins: [
            'https://studio.discovery.microsoft.com'
            'https://*.vscode-cdn.net'
            'https://vscode.dev'
          ]
          allowedMethods: [
            'GET'
            'HEAD'
            'DELETE'
            'PUT'
          ]
          allowedHeaders: [
            '*'
          ]
          exposedHeaders: [
            '*'
          ]
          maxAgeInSeconds: 200
        }
      ]
    }
  }
}

resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobServices
  name: blobContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource storageBlobDataContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, managedIdentity.id, storageBlobDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource discoveryPlatformContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, managedIdentity.id, discoveryPlatformContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      discoveryPlatformContributorRoleId
    )
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource acrPullAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, managedIdentity.id, acrPullRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Grants Discovery Studio (data-plane) access at RG scope. Required so the
// signed-in user can create Agents / Projects / etc. after deployment
// without a manual "az role assignment create" step.
resource discoveryStudioAdminAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in workspaceAdminPrincipalIds: {
    name: guid(resourceGroup().id, principalId, discoveryPlatformAdministratorRoleId)
    properties: {
      roleDefinitionId: subscriptionResourceId(
        'Microsoft.Authorization/roleDefinitions',
        discoveryPlatformAdministratorRoleId
      )
      principalId: principalId
      principalType: workspaceAdminPrincipalType
    }
  }
]

resource supercomputer 'Microsoft.Discovery/supercomputers@2026-06-01' = {
  name: supercomputerName
  location: location
  tags: {
    version: 'v2'
  }
  dependsOn: [
    vnet
    // Roles must exist before the control plane configures NSP.
    discoveryControlPlaneRoles
  ]
  properties: {
    subnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'aksSubnet')
    identities: {
      clusterIdentity: {
        id: managedIdentity.id
      }
      kubeletIdentity: {
        id: managedIdentity.id
      }
      workloadIdentities: {
        '${managedIdentity.id}': {}
      }
    }
  }
}

resource nodePool 'Microsoft.Discovery/supercomputers/nodePools@2026-06-01' = {
  parent: supercomputer
  name: nodePoolName
  location: location
  dependsOn: [
    vnet
  ]
  properties: {
    subnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'supercomputerNodepoolSubnet')
    vmSize: nodePoolVmSize
    maxNodeCount: nodePoolMaxNodeCount
    minNodeCount: nodePoolMinNodeCount
    scaleSetPriority: nodePoolScaleSetPriority
  }
}

resource workspace 'Microsoft.Discovery/workspaces@2026-06-01' = {
  name: workspaceName
  location: location
  tags: {
    version: 'v2'
    'discovery.workbench.enableGhcpAiFeatures': string(enableGhcpAiFeatures)
    'discovery.workbench.enableExtensions': string(enableExtensions)
    NetworkIsolation: string(networkIsolation)
  }
  dependsOn: [
    vnet
    nodePool
    // Roles must exist before the control plane configures NSP.
    discoveryControlPlaneRoles
  ]
  properties: {
    workspaceIdentity: {
      id: managedIdentity.id
    }
    supercomputerIds: [
      supercomputer.id
    ]
    agentSubnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'agentSubnet')
    privateEndpointSubnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'privateEndpointSubnet')
    workspaceSubnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'workspaceSubnet')
  }
}

resource chatModelDeployment 'Microsoft.Discovery/workspaces/chatModelDeployments@2026-06-01' = {
  parent: workspace
  name: chatModelDeploymentName
  location: location
  properties: {
    modelFormat: chatModelFormat
    modelName: chatModelName
  }
}

resource discoveryStorageContainer 'Microsoft.Discovery/storageContainers@2026-06-01' = {
  name: storageContainerName
  location: location
  dependsOn: [
    // Roles must exist before the control plane configures NSP.
    discoveryControlPlaneRoles
  ]
  properties: {
    storageStore: {
      kind: 'AzureStorageBlob'
      storageAccountId: storageAccount.id
    }
  }
}

resource project 'Microsoft.Discovery/workspaces/projects@2026-06-01' = {
  parent: workspace
  name: projectName
  location: location
  dependsOn: [
    chatModelDeployment
  ]
  properties: {
    storageContainerIds: [
      discoveryStorageContainer.id
    ]
  }
}

@description('Resource ID of the Supercomputer.')
output supercomputerId string = supercomputer.id

@description('Resource ID of the Node Pool.')
output nodePoolId string = nodePool.id

@description('Resource ID of the Workspace.')
output workspaceId string = workspace.id

@description('Resource ID of the Chat Model Deployment.')
output chatModelDeploymentId string = chatModelDeployment.id

@description('Resource ID of the Discovery Storage Container.')
output storageContainerId string = discoveryStorageContainer.id

@description('Resource ID of the Project.')
output projectId string = project.id

@description('Resource ID of the User-Assigned Managed Identity.')
output managedIdentityId string = managedIdentity.id

@description('Resource ID of the Storage Account.')
output storageAccountId string = storageAccount.id

@description('Resource ID of the Virtual Network.')
output vnetId string = vnet.id