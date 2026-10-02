#requires -Version 7.2
<#
.SYNOPSIS
Removes only the dedicated resource group owned by a saved demo deployment.
.PARAMETER StatePath
State file whose ownership tag must match Azure before deletion.
.EXAMPLE
.\scripts\Remove-Demo.ps1 -Confirm:$false
.OUTPUTS
None. Throws if Azure has not removed the group.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param([string]$StatePath = (Join-Path $PSScriptRoot '..\artifacts\state.json'))
. "$PSScriptRoot\Common.ps1"
$state = Read-DemoState $StatePath
$exists = Invoke-Azure @('group','exists','--name',$state.resourceGroup,'--subscription',$state.subscriptionId)
if (-not $exists) { Write-Verbose 'Resource group already removed.'; return }
$group = Invoke-Azure @('group','show','--name',$state.resourceGroup,'--subscription',$state.subscriptionId)
if ($group.tags.demoOwnershipId -ne $state.ownershipId) { throw 'Ownership tag mismatch: refusing deletion.' }
if ($PSCmdlet.ShouldProcess("$($state.subscriptionId)/$($state.resourceGroup)", 'Delete all demo resources')) {
    if ($state.publicIp) {
        try {
            Invoke-DemoSsh $state 'sudo bash /home/demoadmin/demo/scripts/linux/outage.sh stop' | Out-Host
        } catch {
            Write-Warning "Cannot restore guest connectivity: $($_.Exception.Message). Deleting the owned VM and group through ARM."
        }
    }
    Invoke-Azure @('group','delete','--name',$state.resourceGroup,'--subscription',$state.subscriptionId,'--yes') | Out-Null
    if (Invoke-Azure @('group','exists','--name',$state.resourceGroup,'--subscription',$state.subscriptionId)) {
        throw 'Resource group still exists after deletion.'
    }
}
