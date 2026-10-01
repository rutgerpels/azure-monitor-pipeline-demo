targetScope = 'resourceGroup'

@description('Short unique demo name. All resources belong to a dedicated resource group.')
param name string
param location string = 'westeurope'
param vmSize string = 'Standard_D4s_v6'
param adminUsername string = 'demoadmin'
@description('SSH public key, never the private key.')
param sshPublicKey string
@description('Presenter IPv4 CIDR; only SSH is exposed publicly.')
param adminCidr string
param useRunCommand bool = false

var tags = { application: 'azure-monitor-pipeline-demo' }

resource nsg 'Microsoft.Network/networkSecurityGroups@2026-05-01' = {
  name: '${name}-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'presenter-ssh'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: useRunCommand ? 'Deny' : 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: adminCidr
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'deny-other-inbound'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}
resource vnet 'Microsoft.Network/virtualNetworks@2026-05-01' = {
  name: '${name}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: ['10.80.0.0/24'] }
    subnets: [
      {
        name: 'site'
        properties: {
          addressPrefix: '10.80.0.0/24'
          defaultOutboundAccess: false
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}
resource publicIp 'Microsoft.Network/publicIPAddresses@2026-05-01' = {
  name: '${name}-ip'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}
resource nic 'Microsoft.Network/networkInterfaces@2026-05-01' = {
  name: '${name}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'site'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.80.0.4'
          subnet: { id: '${vnet.id}/subnets/site' }
          publicIPAddress: { id: publicIp.id }
        }
      }
    ]
  }
}
resource vm 'Microsoft.Compute/virtualMachines@2026-04-01' = {
  name: '${name}-vm'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      // The buffer lives on this durable managed OS disk, not temporary VM storage.
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 64
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
        deleteOption: 'Delete'
      }
    }
    osProfile: {
      computerName: '${name}-vm'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        provisionVMAgent: true
        ssh: {
          publicKeys: [
            { path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: sshPublicKey }
          ]
        }
      }
    }
    networkProfile: { networkInterfaces: [{ id: nic.id }] }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: { secureBootEnabled: true, vTpmEnabled: true }
    }
  }
}
resource workspace 'Microsoft.OperationalInsights/workspaces@2026-03-01' = {
  name: '${name}-logs'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    workspaceCapping: { dailyQuotaGb: 1 }
  }
}
resource sentinel 'Microsoft.OperationsManagement/solutions@2015-11-01-preview' = {
  name: 'SecurityInsights(${workspace.name})'
  location: location
  plan: {
    name: 'SecurityInsights(${workspace.name})'
    publisher: 'Microsoft'
    product: 'OMSGallery/SecurityInsights'
    promotionCode: ''
  }
  properties: { workspaceResourceId: workspace.id }
}

output publicIp string = publicIp.properties.ipAddress
output vmName string = vm.name
output workspaceId string = workspace.id
output workspaceCustomerId string = workspace.properties.customerId
output workspaceName string = workspace.name
output vmPrincipalId string = vm.identity.principalId
