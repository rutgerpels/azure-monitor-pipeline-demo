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
// Built-in processors populate attributes; every exporter still needs an explicit record map.
// https://learn.microsoft.com/azure/azure-monitor/data-collection/pipeline-configure-cli
var syslogFields = [
  'CollectorHostName', 'Computer', 'EventTime', 'Facility', 'HostIP', 'HostName'
  'ProcessID', 'ProcessName', 'SeverityLevel', 'SourceSystem', 'SyslogMessage', 'TimeGenerated'
]
var cefFields = [
  'Computer', 'TimeGenerated', 'CollectorHostName', 'DeviceVendor', 'DeviceProduct', 'DeviceVersion'
  'DeviceEventClassID', 'Activity', 'LogSeverity', 'OriginalLogSeverity', 'AdditionalExtensions'
  'ApplicationProtocol', 'EventCount', 'DestinationDnsDomain', 'DestinationServiceName'
  'DestinationTranslatedAddress', 'DestinationTranslatedPort', 'CommunicationDirection', 'DeviceDnsDomain'
  'DeviceExternalID', 'DeviceFacility', 'DeviceInboundInterface', 'DeviceName', 'DeviceNtDomain'
  'DeviceOutboundInterface', 'DevicePayloadId', 'ProcessName', 'DeviceTranslatedAddress'
  'DestinationHostName', 'DestinationMACAddress', 'DestinationNTDomain', 'DestinationProcessId'
  'DestinationUserPrivileges', 'DestinationProcessName', 'DestinationPort', 'DestinationIP', 'DeviceTimeZone'
  'DestinationUserID', 'DestinationUserName', 'DeviceAddress', 'DeviceMacAddress', 'ProcessID', 'ExternalID', 'ExtID'
  'FileCreateTime', 'FileHash', 'FileID', 'FileModificationTime', 'FilePath', 'FilePermission', 'FileType'
  'FileName', 'FileSize', 'ReceivedBytes', 'Message', 'OldFileCreateTime', 'OldFileHash', 'OldFileID'
  'OldFileModificationTime', 'OldFileName', 'OldFilePath', 'OldFilePermission', 'OldFileSize', 'OldFileType'
  'SentBytes', 'EventOutcome', 'Protocol', 'Reason', 'RequestURL', 'RequestClientApplication', 'RequestContext'
  'RequestCookies', 'RequestMethod', 'ReceiptTime', 'SourceHostName', 'SourceMACAddress', 'SourceNTDomain'
  'SourceDnsDomain', 'SourceServiceName', 'SourceTranslatedAddress', 'SourceTranslatedPort', 'SourceProcessId'
  'SourceUserPrivileges', 'SourceProcessName', 'SourcePort', 'SourceIP', 'SourceUserID', 'SourceUserName'
  'EventType', 'DeviceEventCategory', 'DeviceCustomIPv6Address1', 'DeviceCustomIPv6Address1Label'
  'DeviceCustomIPv6Address2', 'DeviceCustomIPv6Address2Label', 'DeviceCustomIPv6Address3'
  'DeviceCustomIPv6Address3Label', 'DeviceCustomIPv6Address4', 'DeviceCustomIPv6Address4Label'
  'DeviceCustomFloatingPoint1', 'DeviceCustomFloatingPoint1Label', 'DeviceCustomFloatingPoint2'
  'DeviceCustomFloatingPoint2Label', 'DeviceCustomFloatingPoint3', 'DeviceCustomFloatingPoint3Label'
  'DeviceCustomFloatingPoint4', 'DeviceCustomFloatingPoint4Label', 'DeviceCustomNumber1'
  'FieldDeviceCustomNumber1', 'DeviceCustomNumber1Label', 'DeviceCustomNumber2', 'FieldDeviceCustomNumber2'
  'DeviceCustomNumber2Label', 'DeviceCustomNumber3', 'FieldDeviceCustomNumber3', 'DeviceCustomNumber3Label'
  'DeviceCustomString1', 'DeviceCustomString1Label', 'DeviceCustomString2', 'DeviceCustomString2Label'
  'DeviceCustomString3', 'DeviceCustomString3Label', 'DeviceCustomString4', 'DeviceCustomString4Label'
  'DeviceCustomString5', 'DeviceCustomString5Label', 'DeviceCustomString6', 'DeviceCustomString6Label'
  'DeviceCustomDate1', 'DeviceCustomDate1Label', 'DeviceCustomDate2', 'DeviceCustomDate2Label'
  'FlexDate1', 'FlexDate1Label', 'FlexNumber1', 'FlexNumber1Label', 'FlexNumber2', 'FlexNumber2Label'
  'FlexString1', 'FlexString1Label', 'FlexString2', 'FlexString2Label', 'DeviceAction'
  'SimplifiedDeviceAction', 'RemoteIP', 'RemotePort', 'SourceSystem'
]
var syslogMap = [for field in syslogFields: { from: 'attributes.${field}', to: field }]
var cefMap = [for field in cefFields: { from: 'attributes.${field}', to: field }]
var filteredMap = [for field in filteredFields: { from: 'attributes.${field}', to: field }]
var recordMaps = { baseline: syslogMap, cef: cefMap, filtered: filteredMap }

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
          transformStatement: 'source | extend payload = parse_json(SyslogMessage) | where tobool(payload[\'noise\']) == false | project TimeGenerated, RunId = tostring(payload[\'runId\']), Sequence = tolong(payload[\'sequence\']), Device = tostring(payload[\'device\']), Message = tostring(payload[\'message\'])'
        }
      }
    ]
    exporters: [for item in streams: {
      name: '${item.name}-exporter'
      type: 'AzureMonitorWorkspaceLogs'
      azureMonitorWorkspaceLogs: {
        api: {
          dataCollectionEndpointUrl: endpointUrl
          dataCollectionRule: ruleId
          stream: item.stream
          schema: { recordMap: recordMaps[item.name] }
        }
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
