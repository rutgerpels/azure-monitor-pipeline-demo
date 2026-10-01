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
        $node.GetCommandName() -eq 'Invoke-DemoSsh' -and $node.Extent.Text.Contains('clusterissuer')
}, $true)
$pipelineDeployment = $deployAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Invoke-DemoDeployment' -and $node.Extent.Text.Contains("'pipeline'")
}, $true)
Assert-True ($null -ne $issuerCheck -and $null -ne $pipelineDeployment) 'Certificate readiness guard or pipeline deployment is missing.'
Assert-True ($issuerCheck.Extent.StartOffset -lt $pipelineDeployment.Extent.StartOffset) 'Certificate readiness must precede pipeline creation.'
Assert-True ($issuerCheck.Extent.Text.Contains('--timeout=180s') -and $issuerCheck.Extent.Text.Contains('exit 1')) 'Certificate readiness must time out and fail explicitly.'

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
    if ($content -notmatch 'DEMO_BEGIN_([a-f0-9]{32})') { throw 'Missing completion marker.' }
    $token = $Matches[1]
    [pscustomobject]@{ value = @([pscustomobject]@{
        message = "Enable succeeded: `n[stdout]`nDEMO_BEGIN_$token`nhello`nDEMO_EXIT_$token=$script:remoteCode`n[stderr]`n"
    }) }
}
try {
    Assert-True ((Invoke-DemoSsh $state 'echo hello') -eq 'hello') 'Run Command output was not extracted.'
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
