param name string
param location string = 'westeurope'
param customLocationId string
param endpointUrl string
param ruleId string
param workspaceName string

var streams = [
  { name: 'baseline', port: 1514, format: 'syslogRfc5424', stream: 'Microsoft-Syslog-FullyFormed' }
  { name: 'cef', port: 1515, format: 'cefRfc3164', stream: 'Microsoft-CommonSecurityLog-FullyFormed' }
  { name: 'filtered', port: 1516, format: 'syslogRfc5424', stream: 'Custom-NetworkDemoFiltered' }
]
var filteredFields = ['TimeGenerated', 'RunId', 'Sequence', 'Device', 'Message']
var filteredMap = [for field in filteredFields: { from: 'attributes.${field}', to: field }]

resource pipeline 'Microsoft.Monitor/pipelineGroups@2026-04-01' = {
  name: '${name}-pipeline'
  location: location
  extendedLocation: { name: customLocationId, type: 'CustomLocation' }
  properties: {
    replicas: 1
    // Synthetic traffic stays on this VM. Never expose these plaintext receivers publicly.
    tlsConfigurations: [{ name: 'private-demo', mode: 'disabled' }]
    receivers: [for item in streams: {
      name: '${item.name}-receiver'
      type: 'Syslog'
      tlsConfiguration: 'private-demo'
      syslog: {
        endpoint: '0.0.0.0:${item.port}'
        transportProtocol: 'tcp'
        allowedFormats: [item.format]
      }
    }]
    processors: [
      { name: 'syslog-schema', type: 'MicrosoftSyslog' }
      { name: 'cef-schema', type: 'MicrosoftCommonSecurityLog' }
      {
        name: 'filter-reshape'
        type: 'TransformLanguage'
        transformLanguage: {
          transformStatement: 'source | extend payload = parse_json(SyslogMessage) | where tobool(payload.noise) == false | project TimeGenerated, RunId = tostring(payload.runId), Sequence = tolong(payload.sequence), Device = tostring(payload.device), Message = tostring(payload.message)'
        }
      }
    ]
    exporters: [for item in streams: {
      name: '${item.name}-exporter'
      type: 'AzureMonitorWorkspaceLogs'
      azureMonitorWorkspaceLogs: {
        api: union({
          dataCollectionEndpointUrl: endpointUrl
          dataCollectionRule: ruleId
          stream: item.stream
        }, item.name == 'filtered' ? {
          schema: { recordMap: filteredMap }
        } : {})
        persistence: { maxStorageUsage: 1, retentionPeriod: 120 }
      }
    }]
    service: {
      persistence: { persistentVolumeName: 'pipeline-buffer' }
      pipelines: [for item in streams: {
        name: '${item.name}-flow'
        type: 'Logs'
        receivers: ['${item.name}-receiver']
        processors: item.name == 'cef' ? ['cef-schema'] : item.name == 'filtered' ? ['syslog-schema', 'filter-reshape'] : ['syslog-schema']
        exporters: ['${item.name}-exporter']
      }]
    }
  }
}
resource workspace 'Microsoft.OperationalInsights/workspaces@2026-03-01' existing = {
  name: workspaceName
}
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'demo-health'
  scope: pipeline
  properties: {
    workspaceId: workspace.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}
output pipelineId string = pipeline.id
