#requires -Version 7.2
[CmdletBinding()]
param()
. "$PSScriptRoot\..\scripts\Common.ps1"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

Assert-True ((Resolve-DemoVersion PipelineVersion '1.6.0' '1.7.0' $false) -eq '1.6.0') 'Resume lost recorded pipeline version.'
Assert-True ((Resolve-DemoVersion PipelineReleaseTrain Stable Preview $false) -eq 'Stable') 'Resume lost recorded release train.'
Assert-True ((Resolve-DemoVersion CertificateVersion '0.8.0' '' $false) -eq '0.8.0') 'Resume lost recorded certificate version.'
$rejected = $false
try { Resolve-DemoVersion PipelineVersion '1.6.0' '1.7.0' $true } catch { $rejected = $true }
Assert-True $rejected 'Implicit extension upgrade was accepted.'
$rejected = $false
try { Assert-DemoManagementAccess $false '127.0.0.1/32' } catch { $rejected = $true }
Assert-True $rejected 'SSH resume accepted the HTTPS-only loopback sentinel.'
Assert-DemoManagementAccess $true '127.0.0.1/32'
Assert-DemoManagementAccess $false '203.0.113.10/32'

$testAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot '..\scripts\Test-Demo.ps1'), [ref]$null, [ref]$null)
$queryFunction = $testAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-RecordQuery'
}, $true)
. ([scriptblock]::Create($queryFunction.Extent.Text))
$cefQuery = Get-RecordQuery 'demo-regression-cef' CommonSecurityLog
Assert-True ($cefQuery.Contains('Sequence=tolong(FieldDeviceCustomNumber1)')) 'CEF validation must use the populated replacement numeric field.'
$savedQuery = Get-Content (Join-Path $PSScriptRoot '..\queries\01-ingestion.kql') -Raw
Assert-True ($savedQuery.Contains('Sequence = tolong(FieldDeviceCustomNumber1)')) 'Saved CEF query must match live validation.'

$heartbeatQuery = $testAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Invoke-DemoQuery' -and $node.Extent.Text.Contains('"Heartbeat |')
}, $true).Extent.Text
Assert-True ($heartbeatQuery.Contains('_ResourceId =~') -and $heartbeatQuery.Contains("Computer startswith") -and
    -not $heartbeatQuery.Contains('OSMajorVersion')) 'Heartbeat must identify this extension and collector, not the OS version.'

$boundaryAssignment = $testAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$boundary'
}, $true)
$isolationCheck = $testAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text.Contains('$recovered.records')
}, $true)
$boundaryScript = [scriptblock]::Create($boundaryAssignment.Extent.Text)
$isolationScript = [scriptblock]::Create($isolationCheck.Extent.Text)
$culture = [Globalization.CultureInfo]::CurrentCulture
try {
    foreach ($cultureName in @('en-US','nl-NL')) {
        [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($cultureName)
        $evidence = @{ outage = @{ restoredUtc = '2026-10-01T20:46:01.050090684Z' } }
        . $boundaryScript
        foreach ($ingested in @('2026-10-01T20:46:15.3592651Z', [datetime]'2026-10-01T20:46:15.3592651Z')) {
            $recovered = @{ records = @(@{ Ingested = $ingested }) }
            . $isolationScript
        }
        $recovered = @{ records = @(@{ Ingested = [datetime]'2026-10-01T20:45:00Z' }) }
        $rejected = $false
        try { . $isolationScript } catch { $rejected = $_.Exception.Message -like 'Records were ingested before restoration*' }
        Assert-True $rejected 'Actual pre-restoration ingestion was accepted.'
    }
} finally {
    [Globalization.CultureInfo]::CurrentCulture = $culture
}

$template = (Invoke-Native bicep @('build', (Join-Path $PSScriptRoot '..\infra\pipeline.bicep'), '--stdout')) -join "`n" | ConvertFrom-Json
$pipeline = $template.resources | Where-Object type -eq 'Microsoft.Monitor/pipelineGroups'
$transform = ($pipeline.properties.processors | Where-Object name -eq 'filter-reshape').transformLanguage.transformStatement
foreach ($key in @('noise','runId','sequence','device','message')) {
    Assert-True ($transform.Contains("payload['$key']")) "Local KQL must use bracket access for $key."
}

$deployAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot '..\scripts\Deploy-Demo.ps1'), [ref]$null, [ref]$null)
$cachedOidGuard = $deployAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text.Contains('$CustomLocationsOid = $state.customLocationsOid')
}, $true)
Assert-True ($null -ne $cachedOidGuard) 'Cannot find the deployment object-ID cache guard.'
$cachedOidScript = [scriptblock]::Create($cachedOidGuard.Extent.Text)
function Test-CachedObjectId {
    param([string]$Recorded, [ValidatePattern('^[a-fA-F0-9-]{36}$')][string]$CustomLocationsOid)
    $state = [pscustomobject]@{ customLocationsOid = $Recorded }
    . $cachedOidScript
    $CustomLocationsOid
}
$recordedOid = '00000000-0000-0000-0000-000000000001'
$explicitOid = '00000000-0000-0000-0000-000000000002'
Assert-True ([string]::IsNullOrEmpty((Test-CachedObjectId ''))) 'An empty cache should allow directory lookup.'
Assert-True ((Test-CachedObjectId $recordedOid) -eq $recordedOid) 'Recorded object ID was not reused.'
Assert-True ((Test-CachedObjectId $recordedOid $explicitOid) -eq $explicitOid) 'Explicit object ID was overwritten.'

$issuerCheck = $deployAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Invoke-DemoSsh' -and
        $node.Extent.Text.Contains('Pipeline certificate issuers are not Ready')
}, $true)
$pipelineDeployment = $deployAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Invoke-DemoDeployment' -and $node.Extent.Text.Contains("'pipeline'")
}, $true)
Assert-True ($null -ne $issuerCheck -and $null -ne $pipelineDeployment) 'Certificate readiness guard or pipeline deployment is missing.'
Assert-True ($issuerCheck.Extent.StartOffset -lt $pipelineDeployment.Extent.StartOffset) 'Certificate readiness must precede pipeline creation.'
Assert-True ($issuerCheck.Extent.Text.Contains('--timeout=180s') -and $issuerCheck.Extent.Text.Contains('exit 1')) 'Certificate readiness must time out and fail explicitly.'
$repairSwitch = $deployAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'AllowDemoCertificateRepair' }
Assert-True ($null -ne $repairSwitch -and $null -eq $repairSwitch.DefaultValue) 'Certificate repair must be explicit, never enabled by default.'
$repairGuard = $deployAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -eq '$AllowDemoCertificateRepair'
}, $true)
Assert-True ($null -ne $repairGuard) 'Missing opt-in repair guard.'
$script:remoteCommands = @()
function Invoke-DemoSsh {
    param($State, [string]$Command)
    $script:remoteCommands += $Command
}
$repairGuardScript = [scriptblock]::Create($repairGuard.Extent.Text)
$AllowDemoCertificateRepair = $false
$state = [pscustomobject]@{}
. $repairGuardScript
Assert-True (-not ($script:remoteCommands -match 'python3')) 'Default deployment invoked the repair.'
Assert-True ([bool]($script:remoteCommands -match 'Explicitly pass AllowDemoCertificateRepair')) 'Default deployment must reject previously repaired clusters.'
. "$PSScriptRoot\..\scripts\Common.ps1"

$directory = Join-Path $PSScriptRoot "..\artifacts\orchestration-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory $directory -Force | Out-Null
$state = [pscustomobject]@{
    artifactsPath = [IO.Path]::GetFullPath($directory); useRunCommand = $true
    resourceGroup = 'test-group'; vmName = 'test-vm'; subscriptionId = 'test-subscription'
    workspaceCustomerId = 'test-workspace'
}
$script:remoteCode = 0
function Invoke-Azure {
    param([string[]]$Arguments)
    $file = $Arguments[-1].TrimStart('@')
    $content = Get-Content $file -Raw
    $encodedCommand = [regex]::Match($content, "printf '%s' '([A-Za-z0-9+/=]+)'").Groups[1].Value
    $decodedCommand = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedCommand))
    Assert-True (-not $decodedCommand.Contains("`r")) 'Guest command retained Windows line endings.'
    if ($content -notmatch 'DEMO_BEGIN_([a-f0-9]{32})') { throw 'Missing completion marker.' }
    $token = $Matches[1]
    [pscustomobject]@{ value = @([pscustomobject]@{
        message = "Enable succeeded: `n[stdout]`nDEMO_BEGIN_$token`nhello`nDEMO_EXIT_$token=$script:remoteCode`n[stderr]`n"
    }) }
}
try {
    Assert-True ((Invoke-DemoSsh $state 'echo hello') -eq 'hello') 'Run Command output was not extracted.'
    Assert-True ((Invoke-DemoSsh $state "if true; then`r`necho hello`r`nfi") -eq 'hello') 'Multiline Windows guest command failed.'
    $script:remoteCode = 7
    $rejected = $false
    try { Invoke-DemoSsh $state 'exit 7' } catch { $rejected = $_.Exception.Message -match 'Remote command failed' }
    Assert-True $rejected 'Guest failure was mistaken for ARM provisioning success.'
    Assert-True (@(Get-ChildItem $directory).Count -eq 0) 'Temporary command payload remains.'
} finally {
    Remove-Item $directory
}
function Invoke-Azure { throw "Failed to resolve table expression named 'Syslog'" }
Assert-True (@(Invoke-DemoQuery $state 'Syslog' -AllowMissingTable).Count -eq 0) 'Expected first-ingestion retry failed.'
function Invoke-Azure { throw 'AuthorizationFailed: permission denied' }
$rejected = $false
try { Invoke-DemoQuery $state 'Syslog' -AllowMissingTable } catch { $rejected = $true }
Assert-True $rejected 'Query authorization failure was hidden.'

$script:queryAttempts = 0
function Invoke-Azure {
    $script:queryAttempts++
    if ($script:queryAttempts -eq 1) { throw 'ConnectionResetError: connection aborted' }
    [pscustomobject]@{ Records = 100 }
}
$retried = Invoke-DemoQuery $state 'Syslog | count' -WarningAction SilentlyContinue
Assert-True ($retried.Records -eq 100 -and $script:queryAttempts -eq 2) 'Transient query failure was not retried.'

$script:queryAttempts = 0
function Invoke-Azure {
    $script:queryAttempts++
    throw 'Read timed out'
}
$rejected = $false
try { Invoke-DemoQuery $state 'Syslog | count' } catch { $rejected = $_.Exception.Message -eq 'Read timed out' }
Assert-True ($rejected -and $script:queryAttempts -eq 3) 'Exhausted query retries must fail after exactly three attempts.'

$state | Add-Member bootstrapRoleId '/subscriptions/test-subscription/resourceGroups/test-group/providers/Microsoft.Authorization/roleAssignments/00000000-0000-0000-0000-000000000001'
$script:assignmentExists = $true
$script:deleteFails = $false
function Invoke-Azure {
    param([string[]]$Arguments)
    switch ($Arguments[2]) {
        list { if ($script:assignmentExists) { [pscustomobject]@{ id = $state.bootstrapRoleId } } }
        delete {
            if ($script:deleteFails) { throw 'Simulated role cleanup failure' }
            $script:assignmentExists = $false
        }
        default { throw 'Unexpected Azure operation in cleanup test.' }
    }
}
# Creation can succeed in Azure while the client loses the response.
try {
    try { throw 'Simulated lost creation response' } finally { Remove-DemoBootstrapRole $state }
} catch {
    Assert-True ($_.Exception.Message -eq 'Simulated lost creation response') 'Unexpected cleanup result.'
}
Assert-True (-not $script:assignmentExists) 'A lost creation response left the recorded assignment behind.'
$script:assignmentExists = $true
$script:deleteFails = $true
$rejected = $false
try { Remove-DemoBootstrapRole $state } catch { $rejected = $true }
Assert-True $rejected 'Role cleanup failure was hidden.'
Assert-True ([bool]$state.bootstrapRoleId) 'Failed cleanup lost its recovery identifier.'
$script:deleteFails = $false
Remove-DemoBootstrapRole $state
Assert-True (-not $script:assignmentExists) 'Resume did not remove the leftover role assignment.'
Write-Output 'Orchestration regression checks passed.'
