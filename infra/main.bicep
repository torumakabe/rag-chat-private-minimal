targetScope = 'subscription'

@description('The name of the environment')
@minLength(1)
@maxLength(64)
param environmentName string

@description('The location for the resources')
@minLength(1)
param location string

@description('The token that ensures resource names are as unique as possible')
param resourceToken string = toLower(uniqueString(subscription().id, environmentName, location))

@description('This setting represents the very purpose of this repository')
@allowed(['Disabled'])
param publicNetworkAccess string = 'Disabled'

// Used for optional CORS support for alternate frontends
param allowedOrigin string = ''

param resourceGroupName string = ''
param appServicePlanName string = ''
param appServiceSkuName string = ''
param storageAccountName string = ''
param ragBlobContainerName string = 'contents'

param azureOpenAIApiVersion string = ''
param azureOpenAIGenerativeModel string = ''
param azureOpenAIGenerativeModelVersion string = ''
param azureOpenAIGenerativeModelDeployType string = ''
param azureOpenAIEmbeddingModel string = ''
param azureOpenAIEmbeddingModelVersion string = ''
param azureOpenAIEmbeddingModelDeployType string = ''
param azureSearchIndexName string = ''

param useVpn bool
param useVM bool
param useAppGw bool

@description('Admin username for the VM')
param vmAdminUserName string = ''
var _vmAdminUserName = empty(vmAdminUserName) ? 'myadmin' : vmAdminUserName

@description('Admin password for the VM')
@secure()
param vmAdminPassword string = ''
@secure()
param defaultVmAdminPassword string = 'P@ssw0rd!${newGuid()}'
var _vmAdminPassword = empty(vmAdminPassword) ? defaultVmAdminPassword : vmAdminPassword

var abbrs = loadJsonContent('abbreviations.json')
var tags = { 'azd-env-name': environmentName }

var msftAllowedOrigins = ['https://portal.azure.com', 'https://ms.portal.azure.com']
var allowedOrigins = reduce(
  filter(union(split(allowedOrigin, ';'), msftAllowedOrigins), o => length(trim(o)) > 0),
  [],
  (cur, next) => union(cur, [next])
)

// For VPN auth
var aadTenant = '${environment().authentication.loginEndpoint}${tenant().tenantId}'
var aadAudience = 'c632b3df-fb67-4d84-bdcf-b95ad541b5c8' // Azure Public
var aadIssuer = 'https://sts.windows.net/${tenant().tenantId}/'

resource targetResourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: !empty(resourceGroupName) ? resourceGroupName : '${abbrs.resourcesResourceGroups}${environmentName}'
  location: location
  tags: tags
}

module logAnalyticsWorkspace 'br/public:avm/res/operational-insights/workspace:0.9.1' = {
  name: 'logAnalyticsWorkspaceDeployment'
  scope: targetResourceGroup
  params: {
    name: '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
    location: location
    tags: tags
  }
}

module appInsights 'br/public:avm/res/insights/component:0.4.2' = {
  name: 'appInsightsDeployment'
  scope: targetResourceGroup
  params: {
    name: '${abbrs.insightsComponents}${resourceToken}'
    workspaceResourceId: logAnalyticsWorkspace.outputs.resourceId
    location: location
    tags: tags
  }
}

module appVnet 'br/public:avm/res/network/virtual-network:0.5.2' = {
  name: 'appVirtualNetworkDeployment'
  scope: targetResourceGroup
  params: {
    addressPrefixes: [
      '10.0.0.0/16'
    ]
    name: '${abbrs.networkVirtualNetworks}app'
    location: location
    tags: tags
    subnets: [
      {
        name: '${abbrs.networkVirtualNetworksSubnets}default'
        addressPrefix: '10.0.0.0/26'
        privateEndpointNetworkPolicies: 'Enabled'
        privateLinkServiceNetworkPolicies: 'Enabled'
      }
      {
        name: '${abbrs.networkVirtualNetworksSubnets}appgw'
        addressPrefix: '10.0.0.64/27'
      }
      {
        name: '${abbrs.networkVirtualNetworksSubnets}app-int'
        addressPrefix: '10.0.0.96/28'
        delegation: 'Microsoft.Web/serverFarms'
      }
    ]
    peerings: useVpn
      ? [
          {
            name: '${abbrs.networkVirtualNetworksVirtualNetworkPeerings}app-to-gw'
            useRemoteGateways: true
            remotePeeringName: '${abbrs.networkVirtualNetworksVirtualNetworkPeerings}gw-to-app'
            remoteVirtualNetworkResourceId: gwVnet.outputs.resourceId
            remotePeeringEnabled: true
            remotePeeringAllowGatewayTransit: true
          }
        ]
      : []
  }
}

module gwVnet 'br/public:avm/res/network/virtual-network:0.5.2' = if (useVpn) {
  name: 'gwVirtualNetworkDeployment'
  scope: targetResourceGroup
  params: {
    addressPrefixes: [
      '10.1.0.0/16'
    ]
    name: '${abbrs.networkVirtualNetworks}gw'
    location: location
    tags: tags
    subnets: [
      {
        name: 'GatewaySubnet'
        addressPrefix: '10.1.0.0/27'
      }
    ]
  }
}

module virtualNetworkGateway 'br/public:avm/res/network/virtual-network-gateway:0.5.0' = if (useVpn) {
  scope: targetResourceGroup
  name: 'virtualNetworkGatewayDeployment'
  params: {
    clusterSettings: {
      clusterMode: 'activePassiveNoBgp'
    }
    gatewayType: 'Vpn'
    name: '${abbrs.networkVirtualNetworkGateways}${resourceToken}'
    vNetResourceId: gwVnet.outputs.resourceId
    allowRemoteVnetTraffic: true
    location: location
    tags: tags
    skuName: 'VpnGw2'
    publicIpZones: []
    vpnGatewayGeneration: 'Generation2'
    vpnType: 'RouteBased'
    vpnClientAadConfiguration: {
      aadTenant: aadTenant
      aadAudience: aadAudience
      aadIssuer: aadIssuer
      vpnAuthenticationTypes: ['AAD']
      vpnClientProtocols: [
        'OpenVPN'
      ]
    }
    vpnClientAddressPoolPrefix: '172.16.201.0/24'
  }
}

module storageBlobPrivateDnsZone 'br/public:avm/res/network/private-dns-zone:0.7.0' = {
  name: 'storageBlobPrivateDnsZoneDeployment'
  scope: targetResourceGroup
  params: {
    name: 'privatelink.blob.${environment().suffixes.storage}'
    tags: tags
    virtualNetworkLinks: [
      {
        virtualNetworkResourceId: appVnet.outputs.resourceId
      }
    ]
  }
}

module storageQueuePrivateDnsZone 'br/public:avm/res/network/private-dns-zone:0.7.0' = {
  name: 'storageQueuePrivateDnsZoneDeployment'
  scope: targetResourceGroup
  params: {
    name: 'privatelink.queue.${environment().suffixes.storage}'
    tags: tags
    virtualNetworkLinks: [
      {
        virtualNetworkResourceId: appVnet.outputs.resourceId
      }
    ]
  }
}

module storageAccount 'br/public:avm/res/storage/storage-account:0.15.0' = {
  name: 'storageAccountDeployment'
  scope: targetResourceGroup
  params: {
    name: !empty(storageAccountName) ? storageAccountName : '${abbrs.storageStorageAccounts}${resourceToken}'
    kind: 'StorageV2'
    location: location
    tags: tags
    skuName: 'Standard_LRS'
    allowBlobPublicAccess: false
    publicNetworkAccess: publicNetworkAccess
    blobServices: {
      containers: [
        {
          name: ragBlobContainerName
        }
      ]
    }
    privateEndpoints: [
      {
        service: 'blob'
        tags: tags
        subnetResourceId: appVnet.outputs.subnetResourceIds[0]
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            { privateDnsZoneResourceId: storageBlobPrivateDnsZone.outputs.resourceId }
          ]
        }
      }
      {
        service: 'queue'
        tags: tags
        subnetResourceId: appVnet.outputs.subnetResourceIds[0]
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            { privateDnsZoneResourceId: storageQueuePrivateDnsZone.outputs.resourceId }
          ]
        }
      }
    ]
  }
}

module serverfarm 'br/public:avm/res/web/serverfarm:0.4.1' = {
  name: 'serverfarmDeployment'
  scope: targetResourceGroup
  params: {
    name: !empty(appServicePlanName) ? appServicePlanName : '${abbrs.webServerFarms}${resourceToken}'
    location: location
    tags: tags
    skuName: appServiceSkuName
    skuCapacity: 1
    kind: 'linux'
    zoneRedundant: false
  }
}

module sitesPrivateDnsZone 'br/public:avm/res/network/private-dns-zone:0.7.0' = {
  name: 'sitesPrivateDnsZoneDeployment'
  scope: targetResourceGroup
  params: {
    name: 'privatelink.azurewebsites.net'
    tags: tags
    virtualNetworkLinks: [
      {
        virtualNetworkResourceId: appVnet.outputs.resourceId
      }
    ]
  }
}

var appEnvVariables = {
  RUNNING_IN_PRODUCTION: 'false'
}

module frontend 'br/public:avm/res/web/site:0.13.0' = {
  name: 'frontendSiteDeployment'
  scope: targetResourceGroup
  params: {
    kind: 'app,linux'
    name: '${abbrs.webSitesAppService}frontend-${resourceToken}'
    serverFarmResourceId: serverfarm.outputs.resourceId
    location: location
    tags: union(tags, { 'azd-service-name': 'frontend' })
    appSettingsKeyValuePairs: union(appEnvVariables, {
      ENABLE_ORYX_BUILD: 'True'
      SCM_DO_BUILD_DURING_DEPLOYMENT: 'True'
      APPLICATIONINSIGHTS_CONNECTION_STRING: appInsights.outputs.connectionString
      CHAT_API_ENDPOINT: 'https://${backend.outputs.name}.azurewebsites.net/api/chat'
    })
    siteConfig: {
      linuxFxVersion: 'python|3.11'
      alwaysOn: appServiceSkuName != 'F1'
      use32BitWorkerProcess: appServiceSkuName == 'F1'
      cors: {
        allowedOrigins: allowedOrigins
      }
      appCommandLine: 'python -m streamlit run app.py --server.port $PORT --server.address 0.0.0.0'
    }
    managedIdentities: {
      systemAssigned: true
    }
    virtualNetworkSubnetId: appVnet.outputs.subnetResourceIds[2]
    publicNetworkAccess: publicNetworkAccess
    privateEndpoints: [
      {
        service: 'sites'
        tags: tags
        subnetResourceId: appVnet.outputs.subnetResourceIds[0]
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            { privateDnsZoneResourceId: sitesPrivateDnsZone.outputs.resourceId }
          ]
        }
      }
    ]
  }
}

module frontendToStorageRoleAssignment 'core/security/role-storageaccount.bicep' = {
  scope: targetResourceGroup
  name: 'frontendToStorageRoleAssignment'
  params: {
    storageAccountName: storageAccount.outputs.name
    principalId: frontend.outputs.systemAssignedMIPrincipalId
    roleDefinitionId: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' // Storage Blob Data Contributor
    principalType: 'ServicePrincipal'
  }
}

module admin 'br/public:avm/res/web/site:0.13.0' = {
  name: 'adminSiteDeployment'
  scope: targetResourceGroup
  params: {
    kind: 'app,linux'
    name: '${abbrs.webSitesAppService}admin-${resourceToken}'
    serverFarmResourceId: serverfarm.outputs.resourceId
    location: location
    tags: union(tags, { 'azd-service-name': 'admin' })
    appSettingsKeyValuePairs: union(appEnvVariables, {
      ENABLE_ORYX_BUILD: 'True'
      SCM_DO_BUILD_DURING_DEPLOYMENT: 'True'
      APPLICATIONINSIGHTS_CONNECTION_STRING: appInsights.outputs.connectionString
      AZURE_STORAGE_ACCOUNT_NAME: storageAccount.outputs.name
      RAG_BLOB_CONTAINER_NAME: ragBlobContainerName
    })
    siteConfig: {
      linuxFxVersion: 'python|3.11'
      alwaysOn: appServiceSkuName != 'F1'
      use32BitWorkerProcess: appServiceSkuName == 'F1'
      cors: {
        allowedOrigins: allowedOrigins
      }
      appCommandLine: 'python -m streamlit run app.py --server.port $PORT --server.address 0.0.0.0'
    }
    managedIdentities: {
      systemAssigned: true
    }
    virtualNetworkSubnetId: appVnet.outputs.subnetResourceIds[2]
    publicNetworkAccess: publicNetworkAccess
    privateEndpoints: [
      {
        service: 'sites'
        tags: tags
        subnetResourceId: appVnet.outputs.subnetResourceIds[0]
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            { privateDnsZoneResourceId: sitesPrivateDnsZone.outputs.resourceId }
          ]
        }
      }
    ]
  }
}

module adminToStorageRoleAssignment 'core/security/role-storageaccount.bicep' = {
  scope: targetResourceGroup
  name: 'adminToStorageRoleAssignment'
  params: {
    storageAccountName: storageAccount.outputs.name
    principalId: admin.outputs.systemAssignedMIPrincipalId
    roleDefinitionId: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' // Storage Blob Data Contributor
    principalType: 'ServicePrincipal'
  }
}

module backend 'br/public:avm/res/web/site:0.13.0' = {
  name: 'backendSiteDeployment'
  scope: targetResourceGroup
  params: {
    kind: 'functionapp,linux'
    name: '${abbrs.webSitesFunctions}backend-${resourceToken}'
    serverFarmResourceId: serverfarm.outputs.resourceId
    location: location
    tags: union(tags, { 'azd-service-name': 'backend' })
    storageAccountRequired: true
    storageAccountResourceId: storageAccount.outputs.resourceId
    storageAccountUseIdentityAuthentication: true
    appSettingsKeyValuePairs: union(appEnvVariables, {
      ENABLE_ORYX_BUILD: 'True'
      SCM_DO_BUILD_DURING_DEPLOYMENT: 'True'
      FUNCTIONS_EXTENSION_VERSION: '~4'
      FUNCTIONS_WORKER_RUNTIME: 'python'
      APPLICATIONINSIGHTS_CONNECTION_STRING: appInsights.outputs.connectionString
      AZURE_OPENAI_ENDPOINT: oaiCogAccount.outputs.endpoint
      AZURE_OPENAI_API_VERSION: azureOpenAIApiVersion
      AZURE_OPENAI_GENERATIVE_MODEL: azureOpenAIGenerativeModel
      AZURE_OPENAI_EMBEDDING_MODEL: azureOpenAIEmbeddingModel
      AZURE_SEARCH_SERVICE_NAME: searchService.outputs.name
      AZURE_SEARCH_INDEX_NAME: azureSearchIndexName
      AZURE_DOC_INTELLIGENCE_ENDPOINT: docIntelliCogAccount.outputs.endpoint
      RAG_BLOB_CONTAINER_NAME: ragBlobContainerName
      PYTHON_ENABLE_INIT_INDEXING: '1'
      PYTHON_ISOLATE_WORKER_DEPENDENCIES: '1'
    })
    siteConfig: {
      linuxFxVersion: 'python|3.11'
      alwaysOn: appServiceSkuName != 'F1'
      use32BitWorkerProcess: appServiceSkuName == 'F1'
      cors: {
        allowedOrigins: allowedOrigins
      }
    }
    managedIdentities: {
      systemAssigned: true
    }
    virtualNetworkSubnetId: appVnet.outputs.subnetResourceIds[2]
    publicNetworkAccess: publicNetworkAccess
    privateEndpoints: [
      {
        service: 'sites'
        tags: tags
        subnetResourceId: appVnet.outputs.subnetResourceIds[0]
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            { privateDnsZoneResourceId: sitesPrivateDnsZone.outputs.resourceId }
          ]
        }
      }
    ]
  }
}

module backendToStorageRoleAssignment1 'core/security/role-storageaccount.bicep' = {
  scope: targetResourceGroup
  name: 'backendToStorageRoleAssignment1'
  params: {
    storageAccountName: storageAccount.outputs.name
    principalId: backend.outputs.systemAssignedMIPrincipalId
    roleDefinitionId: '17d1049b-9a84-46fb-8f53-869881c3d3ab' // Storage Account Contributor
    principalType: 'ServicePrincipal'
  }
}

module backendToStorageRoleAssignment2 'core/security/role-storageaccount.bicep' = {
  scope: targetResourceGroup
  name: 'backendToStorageRoleAssignment2'
  params: {
    storageAccountName: storageAccount.outputs.name
    principalId: backend.outputs.systemAssignedMIPrincipalId
    roleDefinitionId: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' // Storage Blob Data Owner
    principalType: 'ServicePrincipal'
  }
}

module backendToStorageRoleAssignment3 'core/security/role-storageaccount.bicep' = {
  scope: targetResourceGroup
  name: 'backendToStorageRoleAssignment3'
  params: {
    storageAccountName: storageAccount.outputs.name
    principalId: backend.outputs.systemAssignedMIPrincipalId
    roleDefinitionId: '974c5e8b-45b9-4653-ba55-5f855dd0fb88' // Storage Queue Data Contributor
    principalType: 'ServicePrincipal'
  }
}

module backendToOaiRoleAssignment 'core/security/role-cogaccount.bicep' = {
  scope: targetResourceGroup
  name: 'backendToOaiRoleAssignment'
  params: {
    cogServiceAccountName: oaiCogAccount.outputs.name
    principalId: backend.outputs.systemAssignedMIPrincipalId
    roleDefinitionId: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd' // Cognitive Services OpanAI User
    principalType: 'ServicePrincipal'
  }
}

module backendToDIRoleAssignment 'core/security/role-cogaccount.bicep' = {
  scope: targetResourceGroup
  name: 'backendToDIRoleAssignment'
  params: {
    cogServiceAccountName: docIntelliCogAccount.outputs.name
    principalId: backend.outputs.systemAssignedMIPrincipalId
    roleDefinitionId: 'a97b65f3-24c7-4388-baec-2e87135dc908' // Cognitive Services User
    principalType: 'ServicePrincipal'
  }
}

module backendToSearchRoleAssignment1 'core/security/role-search.bicep' = {
  scope: targetResourceGroup
  name: 'backendToSearchRoleAssignment1'
  params: {
    searchServiceName: searchService.outputs.name
    principalId: backend.outputs.systemAssignedMIPrincipalId
    roleDefinitionId: '7ca78c08-252a-4471-8644-bb5ff32d4ba0' // Search Service Contributor
    principalType: 'ServicePrincipal'
  }
}

module backendToSearchRoleAssignment2 'core/security/role-search.bicep' = {
  scope: targetResourceGroup
  name: 'backendToSearchRoleAssignment2'
  params: {
    searchServiceName: searchService.outputs.name
    principalId: backend.outputs.systemAssignedMIPrincipalId
    roleDefinitionId: '8ebe5a00-799e-43f5-93ac-243d3dce84a7' // Search Index Data Contributor
    principalType: 'ServicePrincipal'
  }
}

module oaiPrivateDnsZone 'br/public:avm/res/network/private-dns-zone:0.7.0' = {
  name: 'oaiPrivateDnsZoneDeployment'
  scope: targetResourceGroup
  params: {
    name: 'privatelink.openai.azure.com'
    tags: tags
    virtualNetworkLinks: [
      {
        virtualNetworkResourceId: appVnet.outputs.resourceId
      }
    ]
  }
}

module oaiCogAccount 'br/public:avm/res/cognitive-services/account:0.9.1' = {
  name: 'oaiCognitiveAccountDeployment'
  scope: targetResourceGroup
  params: {
    kind: 'OpenAI'
    name: '${abbrs.cognitiveServicesAccounts}oai-${resourceToken}'
    customSubDomainName: resourceToken
    deployments: [
      {
        model: {
          format: 'OpenAI'
          name: azureOpenAIGenerativeModel
          version: azureOpenAIGenerativeModelVersion
        }
        name: azureOpenAIGenerativeModel
        sku: {
          capacity: 10
          name: azureOpenAIGenerativeModelDeployType
        }
      }
      {
        model: {
          format: 'OpenAI'
          name: azureOpenAIEmbeddingModel
          version: azureOpenAIEmbeddingModelVersion
        }
        name: azureOpenAIEmbeddingModel
        sku: {
          capacity: 10
          name: azureOpenAIEmbeddingModelDeployType
        }
      }
    ]
    location: location
    tags: tags
    publicNetworkAccess: publicNetworkAccess
    privateEndpoints: [
      {
        service: 'account'
        tags: tags
        subnetResourceId: appVnet.outputs.subnetResourceIds[0]
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            { privateDnsZoneResourceId: oaiPrivateDnsZone.outputs.resourceId }
          ]
        }
      }
    ]
  }
}

module cognitivePrivateDnsZone 'br/public:avm/res/network/private-dns-zone:0.7.0' = {
  name: 'cognitivePrivateDnsZoneDeployment'
  scope: targetResourceGroup
  params: {
    name: 'privatelink.cognitiveservices.azure.com'
    tags: tags
    virtualNetworkLinks: [
      {
        virtualNetworkResourceId: appVnet.outputs.resourceId
      }
    ]
  }
}

module docIntelliCogAccount 'br/public:avm/res/cognitive-services/account:0.9.1' = {
  name: 'docIntelliCognitiveAccountDeployment'
  scope: targetResourceGroup
  params: {
    kind: 'FormRecognizer'
    name: '${abbrs.cognitiveServicesDocumentIntelligence}${resourceToken}'
    customSubDomainName: resourceToken
    location: location
    tags: tags
    sku: 'S0'
    publicNetworkAccess: publicNetworkAccess
    privateEndpoints: [
      {
        service: 'account'
        tags: tags
        subnetResourceId: appVnet.outputs.subnetResourceIds[0]
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            { privateDnsZoneResourceId: cognitivePrivateDnsZone.outputs.resourceId }
          ]
        }
      }
    ]
  }
}

module cosmosPrivateDnsZone 'br/public:avm/res/network/private-dns-zone:0.7.0' = {
  name: 'cosmosPrivateDnsZoneDeployment'
  scope: targetResourceGroup
  params: {
    name: 'privatelink.documents.azure.com'
    tags: tags
    virtualNetworkLinks: [
      {
        virtualNetworkResourceId: appVnet.outputs.resourceId
      }
    ]
  }
}

module cosmosDbAccount 'br/public:avm/res/document-db/database-account:0.10.1' = {
  name: 'databaseAccountDeployment'
  scope: targetResourceGroup
  params: {
    name: '${abbrs.documentDBDatabaseAccounts}${resourceToken}'
    location: location
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    tags: tags
    capabilitiesToAdd: [
      'EnableServerless'
    ]
    networkRestrictions: {
      networkAclBypass: 'AzureServices'
      publicNetworkAccess: publicNetworkAccess
    }
    sqlDatabases: [
      {
        name: 'db_conversation_history'
        containers: [
          {
            name: 'conversations'
            paths: ['userId']
          }
        ]
      }
    ]
    privateEndpoints: [
      {
        service: 'Sql'
        tags: tags
        subnetResourceId: appVnet.outputs.subnetResourceIds[0]
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            { privateDnsZoneResourceId: cosmosPrivateDnsZone.outputs.resourceId }
          ]
        }
      }
    ]
  }
}

module searchPrivateDnsZone 'br/public:avm/res/network/private-dns-zone:0.7.0' = {
  name: 'searchPrivateDnsZoneDeployment'
  scope: targetResourceGroup
  params: {
    name: 'privatelink.search.windows.net'
    tags: tags
    virtualNetworkLinks: [
      {
        virtualNetworkResourceId: appVnet.outputs.resourceId
      }
    ]
  }
}

module searchService 'br/public:avm/res/search/search-service:0.8.2' = {
  name: 'searchServiceDeployment'
  scope: targetResourceGroup
  params: {
    name: '${abbrs.searchSearchServices}${resourceToken}'
    location: location
    tags: tags
    sku: 'standard'
    replicaCount: 1
    publicNetworkAccess: publicNetworkAccess
    privateEndpoints: [
      {
        service: 'searchService'
        tags: tags
        subnetResourceId: appVnet.outputs.subnetResourceIds[0]
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            { privateDnsZoneResourceId: searchPrivateDnsZone.outputs.resourceId }
          ]
        }
      }
    ]
    managedIdentities: {
      systemAssigned: true
    }
  }
}

module vaultPrivateDnsZone 'br/public:avm/res/network/private-dns-zone:0.7.0' = {
  name: 'vaultPrivateDnsZoneDeployment'
  scope: targetResourceGroup
  params: {
    name: 'privatelink.vaultcore.azure.net'
    tags: tags
    virtualNetworkLinks: [
      {
        virtualNetworkResourceId: appVnet.outputs.resourceId
      }
    ]
  }
}

module vault 'br/public:avm/res/key-vault/vault:0.11.1' = {
  scope: targetResourceGroup
  name: 'vaultDeployment'
  params: {
    name: '${abbrs.keyVaultVaults}${resourceToken}'
    location: location
    tags: tags
    enablePurgeProtection: false
    enableRbacAuthorization: true
    publicNetworkAccess: publicNetworkAccess
    privateEndpoints: [
      {
        service: 'vault'
        tags: tags
        subnetResourceId: appVnet.outputs.subnetResourceIds[0]
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            { privateDnsZoneResourceId: vaultPrivateDnsZone.outputs.resourceId }
          ]
        }
      }
    ]
  }
}

module virtualMachine 'br/public:avm/res/compute/virtual-machine:0.11.0' = if (useVM) {
  scope: targetResourceGroup
  name: 'virtualMachineDeployment'
  params: {
    adminUsername: _vmAdminUserName
    adminPassword: _vmAdminPassword
    imageReference: {
      offer: 'WindowsServer'
      publisher: 'MicrosoftWindowsServer'
      sku: '2022-datacenter-azure-edition'
      version: 'latest'
    }
    name: '${abbrs.computeVirtualMachines}${resourceToken}'
    nicConfigurations: [
      {
        ipConfigurations: [
          {
            name: 'ipconfig01'
            subnetResourceId: appVnet.outputs.subnetResourceIds[0]
          }
        ]
        nicSuffix: '-nic-01'
      }
    ]
    osDisk: {
      caching: 'ReadWrite'
      diskSizeGB: 128
      managedDisk: {
        storageAccountType: 'Premium_LRS'
      }
    }
    osType: 'Windows'
    vmSize: 'Standard_D2s_v3'
    zone: 0
    extensionAntiMalwareConfig: {
      enabled: true
      settings: {
        AntimalwareEnabled: 'true'
        RealtimeProtectionEnabled: 'true'
      }
    }
    location: location
    tags: tags
    managedIdentities: {
      systemAssigned: true
    }
  }
}

// For outbound only
module appGwPublicIpAddress 'br/public:avm/res/network/public-ip-address:0.7.1' = if (useAppGw) {
  scope: targetResourceGroup
  name: 'appGwPublicIpAddressDeployment'
  params: {
    name: '${abbrs.networkPublicIPAddresses}appgw-${resourceToken}'
    location: location
  }
}

module applicationGateway 'br/public:avm/res/network/application-gateway:0.5.1' = if (useAppGw) {
  scope: targetResourceGroup
  name: 'applicationGatewayDeployment'
  params: {
    name: '${abbrs.networkApplicationGateways}${resourceToken}'
    backendAddressPools: [
      {
        name: 'frontendBackendPool'
        properties: {
          backendAddresses: [
            {
              fqdn: frontend.outputs.defaultHostname
            }
          ]
        }
      }
      {
        name: 'adminBackendPool'
        properties: {
          backendAddresses: [
            {
              fqdn: admin.outputs.defaultHostname
            }
          ]
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'httpsSetting'
        properties: {
          cookieBasedAffinity: 'Disabled'
          pickHostNameFromBackendAddress: true
          port: 443
          protocol: 'Https'
          requestTimeout: 30
        }
      }
    ]
    enableHttp2: true
    frontendIPConfigurations: [
      {
        name: 'private'
        properties: {
          privateIPAddress: '10.0.0.70'
          privateIPAllocationMethod: 'Static'
          subnet: {
            id: appVnet.outputs.subnetResourceIds[1]
          }
        }
      }
      {
        name: 'public'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: appGwPublicIpAddress.outputs.resourceId
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'port80'
        properties: {
          port: 80
        }
      }
    ]
    gatewayIPConfigurations: [
      {
        name: 'apw-ip-configuration'
        properties: {
          subnet: {
            id: appVnet.outputs.subnetResourceIds[1]
          }
        }
      }
    ]
    httpListeners: [
      {
        name: 'httpFrontend'
        properties: {
          frontendIPConfiguration: {
            id: resourceId(
              subscription().subscriptionId,
              targetResourceGroup.name,
              'Microsoft.Network/applicationGateways/frontendIPConfigurations',
              '${abbrs.networkApplicationGateways}${resourceToken}',
              'private'
            )
          }
          frontendPort: {
            id: resourceId(
              subscription().subscriptionId,
              targetResourceGroup.name,
              'Microsoft.Network/applicationGateways/frontendPorts',
              '${abbrs.networkApplicationGateways}${resourceToken}',
              'port80'
            )
          }
          hostNames: [frontend.outputs.defaultHostname]
          protocol: 'http'
          requireServerNameIndication: false
        }
      }
      {
        name: 'httpAdmin'
        properties: {
          frontendIPConfiguration: {
            id: resourceId(
              subscription().subscriptionId,
              targetResourceGroup.name,
              'Microsoft.Network/applicationGateways/frontendIPConfigurations',
              '${abbrs.networkApplicationGateways}${resourceToken}',
              'private'
            )
          }
          frontendPort: {
            id: resourceId(
              subscription().subscriptionId,
              targetResourceGroup.name,
              'Microsoft.Network/applicationGateways/frontendPorts',
              '${abbrs.networkApplicationGateways}${resourceToken}',
              'port80'
            )
          }
          hostNames: [admin.outputs.defaultHostname]
          protocol: 'http'
          requireServerNameIndication: false
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'frontend'
        properties: {
          backendAddressPool: {
            id: resourceId(
              subscription().subscriptionId,
              targetResourceGroup.name,
              'Microsoft.Network/applicationGateways/backendAddressPools',
              '${abbrs.networkApplicationGateways}${resourceToken}',
              'frontendBackendPool'
            )
          }
          backendHttpSettings: {
            id: resourceId(
              subscription().subscriptionId,
              targetResourceGroup.name,
              'Microsoft.Network/applicationGateways/backendHttpSettingsCollection',
              '${abbrs.networkApplicationGateways}${resourceToken}',
              'httpsSetting'
            )
          }
          httpListener: {
            id: resourceId(
              subscription().subscriptionId,
              targetResourceGroup.name,
              'Microsoft.Network/applicationGateways/httpListeners',
              '${abbrs.networkApplicationGateways}${resourceToken}',
              'httpFrontend'
            )
          }
          priority: 200
          ruleType: 'Basic'
        }
      }
      {
        name: 'admin'
        properties: {
          backendAddressPool: {
            id: resourceId(
              subscription().subscriptionId,
              targetResourceGroup.name,
              'Microsoft.Network/applicationGateways/backendAddressPools',
              '${abbrs.networkApplicationGateways}${resourceToken}',
              'adminBackendPool'
            )
          }
          backendHttpSettings: {
            id: resourceId(
              subscription().subscriptionId,
              targetResourceGroup.name,
              'Microsoft.Network/applicationGateways/backendHttpSettingsCollection',
              '${abbrs.networkApplicationGateways}${resourceToken}',
              'httpsSetting'
            )
          }
          httpListener: {
            id: resourceId(
              subscription().subscriptionId,
              targetResourceGroup.name,
              'Microsoft.Network/applicationGateways/httpListeners',
              '${abbrs.networkApplicationGateways}${resourceToken}',
              'httpAdmin'
            )
          }
          priority: 300
          ruleType: 'Basic'
        }
      }
    ]
    sku: 'Standard_v2'
    tags: tags
  }
}

output USE_VPN bool = useVpn
output USE_VM bool = useVM
output USE_APPGW bool = useAppGw
output AZURE_STORAGE_ACCOUNT_NAME string = storageAccount.outputs.name
output RAG_BLOB_CONTAINER_NAME string = ragBlobContainerName
output AZURE_OPENAI_ENDPOINT string = oaiCogAccount.outputs.endpoint
output AZURE_OPENAI_API_VERSION string = azureOpenAIApiVersion
output AZURE_OPENAI_GENERATIVE_MODEL string = azureOpenAIGenerativeModel
output AZURE_OPENAI_EMBEDDING_MODEL string = azureOpenAIEmbeddingModel
output AZURE_SEARCH_SERVICE_NAME string = searchService.outputs.name
output AZURE_SEARCH_INDEX_NAME string = azureSearchIndexName
output AZURE_DOC_INTELLIGENCE_ENDPOINT string = docIntelliCogAccount.outputs.endpoint
output RESOURCE_TOKEN string = resourceToken
