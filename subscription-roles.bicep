// -----------------------------------------------------------------------------
// Subscription-scoped roles required by the Microsoft Discovery control plane.
//
// Reference:
//   https://learn.microsoft.com/en-us/azure/microsoft-discovery/quickstart-infrastructure-portal#b-assign-required-roles-to-discovery-control-plane-service-app
//   https://learn.microsoft.com/en-us/azure/microsoft-discovery/how-to-configure-network-security?tabs=azure-cli#assign-the-nsp-perimeter-joiner-role
//
// This module:
//   1. Creates the "Discovery NSP Perimeter Joiner" custom role at subscription
//      scope so the Discovery control-plane first-party service principal can
//      join Network Security Perimeters when it auto-provisions workspaces,
//      bookshelves, and supercomputers.
//   2. Assigns that custom role to the Discovery control-plane service
//      principal at subscription scope.
//   3. Assigns the built-in "Reader" role to the same principal at
//      subscription scope so it can enumerate resources and validate network
//      configurations.
//
// Prerequisites (enforced by the deploying user, not by Bicep):
//   * The deploying identity has Owner or User Access Administrator on the
//     subscription (custom-role + role-assignment creation is required).
//   * The Discovery first-party service principal already exists in the
//     tenant. If not, run:
//       az ad sp create --id 92c174ac-8e41-4815-a1b7-d81b19ab03ce
// -----------------------------------------------------------------------------

targetScope = 'subscription'

@description('Object ID (not App ID) of the Discovery control-plane service principal in the current tenant. Look up with: az ad sp show --id 92c174ac-8e41-4815-a1b7-d81b19ab03ce --query id -o tsv')
param discoveryControlPlanePrincipalId string

@description('Display name of the custom role. Change the suffix if the default name already exists in the tenant.')
param customRoleName string = 'Discovery NSP Perimeter Joiner FDPO'

// Built-in Reader role definition ID (well-known GUID).
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

// Deterministic GUID for the custom role definition so redeploys are idempotent.
var customRoleGuid = guid(subscription().id, customRoleName)

resource nspPerimeterJoinerRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: customRoleGuid
  properties: {
    roleName: customRoleName
    description: 'Allows the Microsoft Discovery control plane to create NSP inbound access rules for network-hardened workspaces.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.Network/networkSecurityPerimeters/joinPerimeterRule/action'
          'Microsoft.Network/locations/networkSecurityPerimeterOperationStatuses/read'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
    assignableScopes: [
      subscription().id
    ]
  }
}

resource nspPerimeterJoinerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, discoveryControlPlanePrincipalId, customRoleGuid)
  properties: {
    roleDefinitionId: nspPerimeterJoinerRole.id
    principalId: discoveryControlPlanePrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource readerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, discoveryControlPlanePrincipalId, readerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalId: discoveryControlPlanePrincipalId
    principalType: 'ServicePrincipal'
  }
}

@description('Resource ID of the custom "Discovery NSP Perimeter Joiner" role definition.')
output nspPerimeterJoinerRoleId string = nspPerimeterJoinerRole.id

@description('Resource ID of the NSP Perimeter Joiner role assignment.')
output nspPerimeterJoinerAssignmentId string = nspPerimeterJoinerAssignment.id

@description('Resource ID of the Reader role assignment.')
output readerAssignmentId string = readerAssignment.id
