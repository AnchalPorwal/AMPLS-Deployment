param vmName string
param location string = resourceGroup().location
// param loganalyticsworkspace string = 'ampls-law'
param vmAdminUserName string
@secure()
param vmAdminPassword string
param loganalyticsworkspacename string
param logAnalyticsWorkspaceSku string
param VNetCloudNSGName string
param VNetCloudName string
param amplsname string
param amplsprivateendpointname string
param amplspeconnection string
param dnszonegroupname string
param amplsScopedlawname string
param amplsScopedDCEname string

// resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
//   name: loganalyticsworkspace
// }

// Create Log Analytics Workspace
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: loganalyticsworkspacename
  location: location
  properties: {
    sku: {
      name: logAnalyticsWorkspaceSku
    }
    publicNetworkAccessForIngestion:'Disabled'
    retentionInDays: 30
  }
}

resource VNetCloudNSG 'Microsoft.Network/networkSecurityGroups@2019-11-01' = {
  name: VNetCloudNSGName
  location: location
  properties: {
    // securityRules: [
    //   {
    //     name: 'nsgRule'
    //     properties: {
    //       description: 'description'
    //       protocol: 'Tcp'
    //       sourcePortRange: '*'
    //       destinationPortRange: '*'
    //       sourceAddressPrefix: '*'
    //       destinationAddressPrefix: '*'
    //       access: 'Allow'
    //       priority: 100
    //       direction: 'Inbound'
    //     }
    //   }
    // ]
  }
}
// Create VNet
resource VNetCloud 'Microsoft.Network/virtualNetworks@2019-11-01' = {
  name: VNetCloudName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'subnet-main'
        properties: {
          addressPrefix: '10.0.0.0/24'
          networkSecurityGroup: {
            id: VNetCloudNSG.id
          }
        }
      }
      {
        name: 'subnet-pe'
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: {
            id: VNetCloudNSG.id
          }
        }
      }
    ]
  }
 
  resource SubnetMain 'subnets' existing = {
    name: 'subnet-main'
  }
  resource SubnetPE 'subnets' existing = {
    name: 'subnet-pe'
  }
}

    
//To deploy ampls
resource ampls 'Microsoft.Insights/privateLinkScopes@2021-07-01-preview' = {
  name: amplsname
  location: 'global'
  properties: {
    accessModeSettings: {
      queryAccessMode: 'PrivateOnly'
      ingestionAccessMode: 'PrivateOnly'
    }

  }
}

resource amplsprivateendpoint 'microsoft.Network/privateendpoints@2021-05-01' = {
  name: amplsprivateendpointname
  location: location
  properties: {
    subnet: {
      id: VNetCloud::SubnetPE.id
    }
    privateLinkServiceConnections: [
      {
        name: amplspeconnection
        properties: {
          privateLinkServiceId: ampls.id
          groupIds: [
            'azuremonitor' 
          ]
        }
      }  
    ]
  }
  dependsOn: [
    ampls
  ]
}

param zones array = [
  'agentsvc.azure-automation.net'
  'blob.${environment().suffixes.storage}' // blob.core.windows.net
  'monitor.azure.com'
  'ods.opinsights.azure.com'
  'oms.opinsights.azure.com'
]
resource privateDnsZoneForAmpls 'Microsoft.Network/privateDnsZones@2020-06-01' = [for zone in zones: {
  name: 'privatelink.${zone}'
  location: 'global'
  properties: {
  }
}]

// Connect Private DNS Zone to VNet
resource privateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (zone,i) in zones: { 
  parent: privateDnsZoneForAmpls[i]
  name: '${zone}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: VNetCloud.id
    }
  }
}]

// Create Private DNS Zone Group for "amplsprivateendpoint" to register A records automatically
resource peDnsGroupForAmpls 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2021-05-01' = {
  parent: amplsprivateendpoint
  name: dnszonegroupname
  properties: {
    privateDnsZoneConfigs: [
      for (zone,i) in zones: {
        name: privateDnsZoneForAmpls[i].name
        properties: {
          privateDnsZoneId: privateDnsZoneForAmpls[i].id
        }
      }
    ]
  }
}

param keyVaultName string
param keyVaultSubscription string
param keyVaultResourceGroup string

resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' existing = {
  name: keyVaultName
  scope: resourceGroup(keyVaultSubscription, keyVaultResourceGroup)
}


module CreateVM 'vm.bicep' = {
  name: 'vm'
  params: {
    location: location
    subnetId: VNetCloud::SubnetMain.id
    vmName: vmName
    vmAdminUserName: keyVault.getSecret('username')
    vmAdminPassword: keyVault.getSecret('password')
  }
}

// To execute "resource~existing" after "CreateVM" module, include process in the same module and use "dependsOn"
module DC 'dc.bicep' = {
  name: 'dc'
  params: {
    location: location
    vmName: vmName
    LawName: logAnalyticsWorkspace.name
    LawId: logAnalyticsWorkspace.id
    // AMPLS: AMPLS
  }
  dependsOn:[
    CreateVM
  ]
}

resource AmplsScopedLaw 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = {
  name: amplsScopedlawname
  parent: ampls
  properties: {
    linkedResourceId: logAnalyticsWorkspace.id
  }
}

resource AmplsScopedDCE 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = {
  name: amplsScopedDCEname
  parent: ampls
  properties: {
    linkedResourceId: DC.outputs.DCEWindowsId
  }
  dependsOn:[
    AmplsScopedLaw
  ]
}

@description('The name of the private link scope.')
output name string = ampls.name

@description('The resource ID of the private link scope.')
output resourceId string = ampls.id

@description('The resource group the private link scope was deployed into.')
output resourceGroupName string = resourceGroup().name

@description('The location the resource was deployed into.')
output location string = ampls.location
