targetScope = 'resourceGroup'

@description('Azure region. Keep all resources in one region.')
param location string = resourceGroup().location

@description('Managed Identity region. Set this to the existing identity region when resuming a partial deployment.')
param identityLocation string = location

@description('Short lowercase deployment name used in globally unique resource names.')
@minLength(3)
@maxLength(18)
param namePrefix string = 'cdmh-ay'

@description('Immutable public GHCR image, for example ghcr.io/account/cdmh-ay:0.4.0.')
param containerImage string

@description('Five-field UTC cron expression. Set only after the collection schedule is approved.')
param collectorCronUtc string

@secure()
param googleClientSecret string
@secure()
param googleRefreshToken string
@secure()
param microsoftClientSecret string
@secure()
param microsoftBootstrapRefreshToken string
@secure()
param microsoftTokenEncryptionKey string
@secure()
param mcpTokenSigningSecret string

param googleClientId string
param youtubeChannelId string
param ownerGoogleEmail string
param ytReachJobId string = ''
param microsoftClientId string
param microsoftTenantId string = 'consumers'
param mcpAccessTokenTtlSeconds int = 900
param mcpRefreshTokenTtlSeconds int = 15552000
param collectionLookbackDays int = 30
param collectorConcurrency int = 4

var suffix = uniqueString(subscription().subscriptionId, resourceGroup().id, namePrefix)
var environmentName = '${namePrefix}-env'
var webAppName = '${namePrefix}-web'
var jobName = '${namePrefix}-collector'
var identityName = '${namePrefix}-identity'
var cosmosAccountName = toLower(replace('${namePrefix}-${suffix}', '-', ''))
var databaseName = 'cdmh-ay'
var containerName = 'runtime-state'
var publicBaseUrl = 'https://${webAppName}.${environment.properties.defaultDomain}'

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: identityLocation
}

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: environmentName
  location: location
  // Omitting appLogsConfiguration is the ARM representation of no logs
  // destination. The API rejects the literal string "none".
  properties: {}
}

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: cosmosAccountName
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    enableFreeTier: true
    disableLocalAuth: true
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
  }
}

resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-05-15' = {
  parent: cosmos
  name: databaseName
  location: location
  properties: {
    resource: {
      id: databaseName
    }
  }
}

resource runtimeContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  parent: database
  name: containerName
  location: location
  properties: {
    resource: {
      id: containerName
      partitionKey: {
        paths: ['/partitionKey']
        kind: 'Hash'
        version: 2
      }
      indexingPolicy: {
        indexingMode: 'consistent'
        automatic: true
        includedPaths: [{ path: '/*' }]
        excludedPaths: [{ path: '/"_etag"/?' }]
      }
    }
    options: {
      throughput: 400
    }
  }
}

resource runtimeRole 'Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions@2024-05-15' = {
  parent: cosmos
  name: guid(cosmos.id, 'cdmh-ay-runtime-state-writer')
  properties: {
    roleName: 'CDMH AY runtime-state item writer'
    type: 'CustomRole'
    assignableScopes: [cosmos.id]
    permissions: [
      {
        dataActions: [
          'Microsoft.DocumentDB/databaseAccounts/readMetadata'
          'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/read'
          'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/create'
          'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/replace'
        ]
      }
    ]
  }
}

resource runtimeRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-05-15' = {
  parent: cosmos
  name: guid(cosmos.id, identity.id, runtimeRole.id)
  properties: {
    roleDefinitionId: runtimeRole.id
    principalId: identity.properties.principalId
    // Cosmos data-plane RBAC uses its own /dbs/.../colls/... scope syntax,
    // not the ARM sqlDatabases/containers resource ID.
    scope: '${cosmos.id}/dbs/${databaseName}/colls/${containerName}'
  }
}

resource webApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: webAppName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: environment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 3000
        transport: 'auto'
        allowInsecure: false
      }
      secrets: [
        { name: 'google-client-secret', value: googleClientSecret }
        { name: 'google-refresh-token', value: googleRefreshToken }
        { name: 'microsoft-client-secret', value: microsoftClientSecret }
        { name: 'microsoft-bootstrap-refresh-token', value: microsoftBootstrapRefreshToken }
        { name: 'microsoft-token-encryption-key', value: microsoftTokenEncryptionKey }
        { name: 'mcp-token-signing-secret', value: mcpTokenSigningSecret }
      ]
    }
    template: {
      containers: [
        {
          name: 'web'
          image: containerImage
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: union(commonEnvironment, [
            { name: 'PORT', value: '3000' }
            { name: 'PUBLIC_BASE_URL', value: publicBaseUrl }
            { name: 'OWNER_GOOGLE_EMAIL', value: ownerGoogleEmail }
            { name: 'MCP_ACCESS_TOKEN_TTL_SECONDS', value: string(mcpAccessTokenTtlSeconds) }
            { name: 'MCP_REFRESH_TOKEN_TTL_SECONDS', value: string(mcpRefreshTokenTtlSeconds) }
            { name: 'GOOGLE_CLIENT_SECRET', secretRef: 'google-client-secret' }
            { name: 'GOOGLE_REFRESH_TOKEN', secretRef: 'google-refresh-token' }
            { name: 'MICROSOFT_CLIENT_SECRET', secretRef: 'microsoft-client-secret' }
            { name: 'MICROSOFT_REFRESH_TOKEN', secretRef: 'microsoft-bootstrap-refresh-token' }
            { name: 'MICROSOFT_TOKEN_ENCRYPTION_KEY', secretRef: 'microsoft-token-encryption-key' }
            { name: 'MCP_TOKEN_SIGNING_SECRET', secretRef: 'mcp-token-signing-secret' }
          ])
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 1
      }
    }
  }
  dependsOn: [runtimeRoleAssignment]
}

resource collectorJob 'Microsoft.App/jobs@2024-03-01' = {
  name: jobName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    environmentId: environment.id
    configuration: {
      triggerType: 'Schedule'
      replicaTimeout: 3600
      replicaRetryLimit: 1
      scheduleTriggerConfig: {
        cronExpression: collectorCronUtc
        parallelism: 1
        replicaCompletionCount: 1
      }
      secrets: [
        { name: 'google-client-secret', value: googleClientSecret }
        { name: 'google-refresh-token', value: googleRefreshToken }
        { name: 'microsoft-client-secret', value: microsoftClientSecret }
        { name: 'microsoft-bootstrap-refresh-token', value: microsoftBootstrapRefreshToken }
        { name: 'microsoft-token-encryption-key', value: microsoftTokenEncryptionKey }
      ]
    }
    template: {
      containers: [
        {
          name: 'collector'
          image: containerImage
          command: ['node', 'dist/src/cli/collect.js']
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: union(commonEnvironment, [
            { name: 'GOOGLE_CLIENT_SECRET', secretRef: 'google-client-secret' }
            { name: 'GOOGLE_REFRESH_TOKEN', secretRef: 'google-refresh-token' }
            { name: 'MICROSOFT_CLIENT_SECRET', secretRef: 'microsoft-client-secret' }
            { name: 'MICROSOFT_REFRESH_TOKEN', secretRef: 'microsoft-bootstrap-refresh-token' }
            { name: 'MICROSOFT_TOKEN_ENCRYPTION_KEY', secretRef: 'microsoft-token-encryption-key' }
          ])
        }
      ]
    }
  }
  dependsOn: [runtimeRoleAssignment]
}

var commonEnvironment = [
  { name: 'NODE_ENV', value: 'production' }
  { name: 'GOOGLE_CLIENT_ID', value: googleClientId }
  { name: 'YOUTUBE_CHANNEL_ID', value: youtubeChannelId }
  { name: 'YT_REACH_JOB_ID', value: ytReachJobId }
  { name: 'MICROSOFT_CLIENT_ID', value: microsoftClientId }
  { name: 'MICROSOFT_TENANT_ID', value: microsoftTenantId }
  { name: 'AZURE_COSMOS_ENDPOINT', value: cosmos.properties.documentEndpoint }
  { name: 'AZURE_COSMOS_DATABASE_NAME', value: databaseName }
  { name: 'AZURE_COSMOS_CONTAINER_NAME', value: containerName }
  { name: 'AZURE_CLIENT_ID', value: identity.properties.clientId }
  { name: 'COLLECTION_LOOKBACK_DAYS', value: string(collectionLookbackDays) }
  { name: 'COLLECTOR_CONCURRENCY', value: string(collectorConcurrency) }
]

output webBaseUrl string = publicBaseUrl
output mcpEndpoint string = '${publicBaseUrl}/mcp'
output managedIdentityClientId string = identity.properties.clientId
output cosmosEndpoint string = cosmos.properties.documentEndpoint
output collectorScheduleUtc string = collectorCronUtc
