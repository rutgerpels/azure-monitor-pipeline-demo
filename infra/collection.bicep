param name string
param location string = 'westeurope'
param workspaceName string
param extensionPrincipalId string

resource workspace 'Microsoft.OperationalInsights/workspaces@2026-03-01' existing = {
  name: workspaceName
}
var filteredColumns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'RunId', type: 'string' }
  { name: 'Sequence', type: 'long' }
  { name: 'Device', type: 'string' }
  { name: 'Message', type: 'string' }
]
resource filteredTable 'Microsoft.OperationalInsights/workspaces/tables@2026-03-01' = {
  parent: workspace
  name: 'NetworkDemoFiltered_CL'
  properties: {
    plan: 'Analytics'
    retentionInDays: 30
    schema: { name: 'NetworkDemoFiltered_CL', columns: filteredColumns }
  }
}
resource endpoint 'Microsoft.Insights/dataCollectionEndpoints@2024-03-11' = {
  name: '${name}-dce'
  location: location
  properties: { networkAcls: { publicNetworkAccess: 'Enabled' } }
}
resource rule 'Microsoft.Insights/dataCollectionRules@2025-05-11' = {
  name: '${name}-dcr'
  location: location
  kind: 'Direct'
  properties: {
    dataCollectionEndpointId: endpoint.id
    streamDeclarations: {
      'Custom-NetworkDemoFiltered': { columns: filteredColumns }
    }
    destinations: {
      logAnalytics: [{ name: 'demo', workspaceResourceId: workspace.id }]
    }
    dataFlows: [
      {
        streams: ['Microsoft-Syslog-FullyFormed']
        destinations: ['demo']
        transformKql: 'source'
        outputStream: 'Microsoft-Syslog'
      }
      {
        streams: ['Microsoft-CommonSecurityLog-FullyFormed']
        destinations: ['demo']
        transformKql: 'source'
        outputStream: 'Microsoft-CommonSecurityLog'
      }
      {
        streams: ['Custom-NetworkDemoFiltered']
        destinations: ['demo']
        transformKql: 'source'
        outputStream: 'Custom-NetworkDemoFiltered_CL'
      }
    ]
  }
  dependsOn: [filteredTable]
}
resource publisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(rule.id, extensionPrincipalId, 'publisher')
  scope: rule
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
    principalId: extensionPrincipalId
    principalType: 'ServicePrincipal'
  }
}
output endpointUrl string = endpoint.properties.logsIngestion.endpoint
output ruleId string = rule.properties.immutableId
