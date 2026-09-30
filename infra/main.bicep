// =============================================================================
// Cloud Resume Challenge - backend infrastructure (step 12)
//
// Builds everything the visitor counter API needs:
//   Cosmos DB (Table API, serverless) + Counter table
//   Storage account for the Function App (keys disabled, identity only)
//   Log Analytics + Application Insights
//   User-assigned managed identity + least-privilege role assignments
//   Flex Consumption plan + Python Function App with CORS locked down
//
// Deploy:  az deployment group create -g <resource-group> -f infra/main.bicep
// =============================================================================

@description('Azure region for all resources. Defaults to the resource group\'s region.')
param location string = resourceGroup().location

@description('Short project name used in resource names.')
param projectName string = 'cloudresume'

@description('Websites allowed to call the API from a browser (CORS).')
param allowedOrigins array = [
  'https://leemcnutt.dev'
  'https://www.leemcnutt.dev'
]

@description('Upper limit on how many instances the app can scale out to.')
@minValue(40)
@maxValue(1000)
param maximumInstanceCount int = 40

@description('Memory per instance, in MB.')
@allowed([512, 2048, 4096])
param instanceMemoryMB int = 512

// A short hash of the resource group ID. Same resource group = same names on
// every deployment (so re-deploying updates resources instead of duplicating
// them), while a different resource group gets different, globally unique names.
var suffix = take(uniqueString(resourceGroup().id), 6)

var functionAppName = 'func-${projectName}-${suffix}'
var cosmosAccountName = 'cosmos-${projectName}-${suffix}'
var storageAccountName = 'stfunc${projectName}${suffix}' // lowercase letters/numbers only, max 24
var deploymentContainerName = 'app-package-${suffix}'
var tableName = 'Counter'

// Built-in Azure role IDs (the same everywhere, so they're safe to hard-code).
var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

var tags = {
  project: 'cloud-resume'
  managedBy: 'bicep'
}

// -----------------------------------------------------------------------------
// Database: Cosmos DB for Table, serverless
// -----------------------------------------------------------------------------
resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: cosmosAccountName
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    capabilities: [
      { name: 'EnableTable' }
      { name: 'EnableServerless' }
    ]
    minimalTlsVersion: 'Tls12'
    publicNetworkAccess: 'Enabled'
    backupPolicy: {
      type: 'Periodic'
      periodicModeProperties: {
        backupIntervalInMinutes: 240
        backupRetentionIntervalInHours: 8
        backupStorageRedundancy: 'Local'
      }
    }
  }
}

resource counterTable 'Microsoft.DocumentDB/databaseAccounts/tables@2024-11-15' = {
  parent: cosmos
  name: tableName
  properties: {
    resource: {
      id: tableName
    }
  }
}

// -----------------------------------------------------------------------------
// Function App's own storage (host bookkeeping + deployment packages)
// -----------------------------------------------------------------------------
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false // no account keys at all: identity-based access only
    allowCrossTenantReplication: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
  }

  resource blobServices 'blobServices' = {
    name: 'default'

    resource deploymentContainer 'containers' = {
      name: deploymentContainerName
      properties: {
        publicAccess: 'None'
      }
    }
  }
}

// -----------------------------------------------------------------------------
// Monitoring
// -----------------------------------------------------------------------------
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${projectName}-${suffix}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${projectName}-${suffix}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    DisableLocalAuth: true // telemetry must be sent with an Entra ID identity, not just the key
  }
}

// -----------------------------------------------------------------------------
// Identity: one user-assigned identity for the Function App
// -----------------------------------------------------------------------------
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${projectName}-${suffix}'
  location: location
  tags: tags
}

// Least privilege: Blob Data Owner on the Function App's storage only. An
// HTTP-triggered app doesn't need queue or table access on its host storage.
resource blobOwnerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, identity.id, storageBlobDataOwnerRoleId)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource metricsPublisherAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appInsights.id, identity.id, monitoringMetricsPublisherRoleId)
  scope: appInsights
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// -----------------------------------------------------------------------------
// Compute: Flex Consumption plan + Function App
// -----------------------------------------------------------------------------
resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'plan-${projectName}-${suffix}'
  location: location
  tags: tags
  kind: 'functionapp'
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
  properties: {
    reserved: true // Linux
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      minTlsVersion: '1.2'
      cors: {
        allowedOrigins: allowedOrigins
        supportCredentials: false
      }
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: identity.id
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: maximumInstanceCount
        instanceMemoryMB: instanceMemoryMB
      }
      runtime: {
        name: 'python'
        version: '3.12'
      }
    }
  }
  // Grant access before the app exists, so it never starts without permissions.
  dependsOn: [
    blobOwnerAssignment
    metricsPublisherAssignment
  ]

  resource appSettings 'config' = {
    name: 'appsettings'
    properties: {
      // Host storage via managed identity (no connection string, no key)
      AzureWebJobsStorage__accountName: storage.name
      AzureWebJobsStorage__credential: 'managedidentity'
      AzureWebJobsStorage__clientId: identity.properties.clientId

      // Application Insights via managed identity
      APPLICATIONINSIGHTS_CONNECTION_STRING: appInsights.properties.ConnectionString
      APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'ClientId=${identity.properties.clientId};Authorization=AAD'

      // Read by function_app.py. The key is looked up at deployment time and
      // written straight into the app's settings - it never appears in this file.
      COSMOS_CONNECTION_STRING: 'DefaultEndpointsProtocol=https;AccountName=${cosmos.name};AccountKey=${cosmos.listKeys().primaryMasterKey};TableEndpoint=https://${cosmos.name}.table.cosmos.azure.com:443/;'
    }
  }
}

// -----------------------------------------------------------------------------
// Outputs (never output secrets: deployment outputs are readable in the portal)
// -----------------------------------------------------------------------------
output functionAppName string = functionApp.name
output apiUrl string = 'https://${functionApp.properties.defaultHostName}/api/visitorcount'
output cosmosAccountName string = cosmos.name
