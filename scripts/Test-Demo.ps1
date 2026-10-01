#requires -Version 7.2
<#
.SYNOPSIS
Exercises the live demo and saves run-scoped evidence, failing on missing records.
.PARAMETER Scene
Ingestion, Filtering, Backfill, Health, or All.
.PARAMETER StatePath
Deployment state written by Deploy-Demo.ps1.
.PARAMETER RestartCollector
Restart the collector during the outage to additionally test durable storage.
.EXAMPLE
.\scripts\Test-Demo.ps1 -Scene All -RestartCollector
.OUTPUTS
Evidence file path. A failed run never writes status Passed.
#>
[CmdletBinding()]
param(
    [ValidateSet('Ingestion','Filtering','Backfill','Health','All')][string]$Scene = 'All',
    [string]$StatePath = (Join-Path $PSScriptRoot '..\artifacts\state.json'),
    [ValidateRange(20,10000)][int]$Count = 1000,
    [ValidateRange(60,1800)][int]$TimeoutSeconds = 900,
    [switch]$RestartCollector
)
. "$PSScriptRoot\Common.ps1"
$state = Read-DemoState $StatePath
$run = 'demo-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0,6))
$evidence = [ordered]@{ runId=$run; startedUtc=[datetime]::UtcNow.ToString('o'); scene=$Scene; status='Running'; checks=@() }
$evidencePath = Join-Path $state.artifactsPath "$run.json"
Save-DemoJson $evidence $evidencePath

function Send-DemoRecords {
    param([string]$RunId, [string]$Format, [int]$Port)
    Invoke-DemoSsh $state "cd /home/demoadmin/demo && python3 -m simulator --host 10.80.0.4 --port $Port --format $Format --run-id $RunId --count $Count --rate 100 --manifest /home/demoadmin/demo/$RunId.json" | Out-Host
    $manifest = Read-DemoRemoteJson $state "/home/demoadmin/demo/$RunId.json"
    if ($manifest.sentRecords -ne $Count) { throw 'Simulator did not send the full batch.' }
    Save-DemoJson $manifest (Join-Path $state.artifactsPath "$RunId-manifest.json")
}

function Get-RecordQuery {
    param([string]$RunId, [string]$Table)
    switch ($Table) {
        'Syslog' { "Syslog | where TimeGenerated > ago(2h) | extend p=parse_json(SyslogMessage) | where tostring(p.runId)=='$RunId' | project Sequence=tolong(p.sequence), Device=HostName, Bytes=_BilledSize, EventTime=TimeGenerated, Ingested=ingestion_time()" }
        'CommonSecurityLog' { "CommonSecurityLog | where TimeGenerated > ago(2h) | where DeviceCustomString1=='$RunId' | project Sequence=tolong(DeviceCustomNumber1), Device=DeviceName, Vendor=DeviceVendor, Product=DeviceProduct, Bytes=_BilledSize, EventTime=TimeGenerated, Ingested=ingestion_time()" }
        'NetworkDemoFiltered_CL' { "NetworkDemoFiltered_CL | where TimeGenerated > ago(2h) and RunId=='$RunId' | project Sequence, Device, Message, Bytes=_BilledSize, EventTime=TimeGenerated, Ingested=ingestion_time()" }
    }
}

function Wait-DemoRecords {
    param([string]$RunId, [string]$Table, [long[]]$Expected)
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    $query = Get-RecordQuery $RunId $Table
    do {
        $rows = @(Invoke-DemoQuery $state $query -AllowMissingTable)
        $actual = @($rows | ForEach-Object { [long]$_.Sequence } | Sort-Object -Unique)
        $unexpected = @($actual | Where-Object { $_ -notin $Expected })
        if ($unexpected.Count) { throw "$Table contains unexpected sequence IDs: $($unexpected -join ',')" }
        $missing = @($Expected | Where-Object { $_ -notin $actual })
        if (-not $missing.Count) {
            if (@($rows | Where-Object { [string]::IsNullOrWhiteSpace($_.Device) }).Count) { throw "$Table device parsing failed." }
            if ($Table -eq 'CommonSecurityLog' -and @($rows | Where-Object { -not $_.Vendor -or -not $_.Product }).Count) {
                throw 'CEF vendor/product parsing failed.'
            }
            if ($Table -eq 'NetworkDemoFiltered_CL' -and @($rows | Where-Object {
                        [string]::IsNullOrWhiteSpace($_.Message) -or -not $_.EventTime
                    }).Count) { throw 'Filtered Message or source TimeGenerated was lost.' }
            $result = [ordered]@{
                table=$Table; runId=$RunId; expected=$Expected.Count; unique=$actual.Count
                duplicates=($rows.Count-$actual.Count); billedBytes=($rows | Measure-Object Bytes -Sum).Sum
                query=$query; records=$rows
            }
            $evidence.checks += $result
            Save-DemoJson $evidence $evidencePath
            return $result
        }
        Write-Verbose "$Table`: waiting for $($missing.Count) records."
        Start-Sleep -Seconds 15
    } while ([datetime]::UtcNow -lt $deadline)
    throw "$Table timed out with $($missing.Count) missing IDs for $RunId."
}

try {
    if ($Scene -in @('Ingestion','All')) {
        Send-DemoRecords "$run-syslog" syslog 30514
        Send-DemoRecords "$run-cef" cef 30515
        Wait-DemoRecords "$run-syslog" Syslog (1..$Count) | Out-Null
        Wait-DemoRecords "$run-cef" CommonSecurityLog (1..$Count) | Out-Null
    }
    if ($Scene -in @('Filtering','All')) {
        Send-DemoRecords "$run-before" syslog 30514
        Send-DemoRecords "$run-after" syslog 30516
        $before = Wait-DemoRecords "$run-before" Syslog (1..$Count)
        $retained = @(1..$Count | Where-Object { ($_ % 10) -in @(8,9,0) })
        $after = Wait-DemoRecords "$run-after" NetworkDemoFiltered_CL $retained
        if ($after.billedBytes -ge $before.billedBytes) { throw 'Filtered ingestion size did not decrease.' }
        $schema = @(Invoke-DemoQuery $state 'NetworkDemoFiltered_CL | getschema | project ColumnName')
        if (@($schema | Where-Object ColumnName -in @('padding','Padding','SyslogMessage')).Count) { throw 'Verbose field remains in the filtered schema.' }
        $evidence.checks += @{ recordReductionPercent=100*(1-$after.unique/$before.unique); byteReductionPercent=100*(1-$after.billedBytes/$before.billedBytes) }
    }
    if ($Scene -in @('Backfill','All')) {
        $restartArgument = ([bool]$RestartCollector).ToString().ToLowerInvariant()
        Invoke-DemoSsh $state "sudo bash /home/demoadmin/demo/scripts/linux/backfill.sh '$run-outage' $Count '$($state.endpointUrl)' '$($state.pipelineName)' $restartArgument" | Out-Host
        $evidence.outage = Read-DemoRemoteJson $state "/home/demoadmin/demo/$run-outage-backfill.json"
        $manifest = Read-DemoRemoteJson $state "/home/demoadmin/demo/$run-outage.json"
        if ($manifest.sentRecords -ne $Count) { throw 'Incomplete outage batch.' }
        Save-DemoJson $manifest (Join-Path $state.artifactsPath "$run-outage-manifest.json")
        $recovered = Wait-DemoRecords "$run-outage" Syslog (1..$Count)
        $boundary = [datetime]::Parse($evidence.outage.restoredUtc).ToUniversalTime().AddSeconds(-2)
        if (@($recovered.records | Where-Object { [datetime]::Parse($_.Ingested).ToUniversalTime() -lt $boundary }).Count) {
            throw 'Records were ingested before restoration (two-second clock tolerance). Isolation was ineffective.'
        }
    }
    if ($Scene -in @('Health','All')) {
        $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
        do {
            $heartbeat = @(Invoke-DemoQuery $state "Heartbeat | where TimeGenerated > ago(5m) and OSMajorVersion == '$($state.pipelineName)' | summarize LastSeen=max(TimeGenerated), Records=count()" -AllowMissingTable)
            $metrics = @(Invoke-DemoQuery $state "AzureMetrics | where TimeGenerated > ago(30m) and _ResourceId =~ '$($state.pipelineId)' | where MetricName in ('process_cpu_utilization','process_memory_usage','process_uptime') | summarize Samples=count() by MetricName" -AllowMissingTable)
            if ($heartbeat.Count -and $heartbeat[0].Records -gt 0 -and $metrics.Count -eq 3) { break }
            Start-Sleep -Seconds 20
        } while ([datetime]::UtcNow -lt $deadline)
        if (-not $heartbeat.Count -or $heartbeat[0].Records -eq 0 -or $metrics.Count -ne 3) {
            throw 'Fresh pipeline heartbeat or one of the three GA runtime metrics is missing.'
        }
        $evidence.checks += @{ heartbeat=$heartbeat; metrics=$metrics }
    }
    $evidence.status = 'Passed'
} catch {
    $evidence.status = 'Failed'
    $evidence.error = $_.Exception.Message
    throw
} finally {
    $evidence.completedUtc = [datetime]::UtcNow.ToString('o')
    Save-DemoJson $evidence $evidencePath
}
Write-Output $evidencePath
