#requires -Version 7.2
<#
.SYNOPSIS
Deploys an isolated Azure Monitor pipeline demonstration in West Europe.
.DESCRIPTION
Uses Bicep, SSH and Azure Arc. Re-running with the same state resumes the deployment.
.PARAMETER Name
Unique short lowercase name; resources live in rg-<Name>.
.PARAMETER AdminCidr
Presenter's public IPv4 address followed by /32. Only SSH is exposed.
.PARAMETER SubscriptionId
Explicit Azure subscription, defaulting to the current Azure CLI subscription.
.EXAMPLE
.\scripts\Deploy-Demo.ps1 -Name ampdemo01 -AdminCidr 203.0.113.10/32
.OUTPUTS
Deployment state path.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[a-z][a-z0-9-]{3,17}$')][string]$Name = 'ampdemo01',
    [ValidatePattern('^\d{1,3}(\.\d{1,3}){3}/32$')][string]$AdminCidr = '127.0.0.1/32',
    [switch]$UseRunCommand,
    [string]$SubscriptionId,
    [string]$VmSize = 'Standard_D4s_v6',
    [string]$PipelineVersion = '1.7.0',
    [ValidateSet('Stable', 'Preview')][string]$PipelineReleaseTrain = 'Preview',
    [string]$CertificateVersion,
    [ValidatePattern('^[a-fA-F0-9-]{36}$')][string]$CustomLocationsOid,
    [string]$StatePath = (Join-Path $PSScriptRoot '..\artifacts\state.json')
)
. "$PSScriptRoot\Common.ps1"
$root = Split-Path $PSScriptRoot
$account = Invoke-Azure @('account', 'show')
if (-not $SubscriptionId) { $SubscriptionId = $account.id }
foreach ($tool in @('az', 'ssh', 'scp', 'ssh-keygen', 'kubectl', 'bicep', 'python')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required tool missing: $tool" }
}
$installedExtensions = @(Invoke-Azure @('extension', 'list'))
foreach ($extension in @('connectedk8s', 'k8s-extension', 'customlocation', 'log-analytics')) {
    $installed = @($installedExtensions | Where-Object name -eq $extension)
    if (-not $installed.Count) { throw "Install missing Azure CLI extension: az extension add --name $extension" }
}
$artifacts = [IO.Path]::GetFullPath((Split-Path $StatePath))
New-Item -ItemType Directory -Force -Path $artifacts | Out-Null
$StatePath = [IO.Path]::GetFullPath($StatePath)
if (Test-Path $StatePath) {
    $state = Read-DemoState $StatePath
    if ($state.name -ne $Name -or $state.subscriptionId -ne $SubscriptionId) {
        throw 'State belongs to another deployment. Use a different StatePath.'
    }
    foreach ($parameter in @('PipelineVersion','PipelineReleaseTrain','CertificateVersion')) {
        $property = $parameter.Substring(0,1).ToLowerInvariant() + $parameter.Substring(1)
        Set-Variable $parameter (Resolve-DemoVersion $parameter $state.$property `
            (Get-Variable $parameter -ValueOnly) $PSBoundParameters.ContainsKey($parameter))
    }
    if (-not $state.PSObject.Properties['useRunCommand']) { $state | Add-Member useRunCommand $false }
    if ($UseRunCommand) { $state.useRunCommand = $true }
} else {
    $state = [pscustomobject]@{
        name = $Name; resourceGroup = "rg-$Name"; subscriptionId = $SubscriptionId
        artifactsPath = $artifacts; keyPath = (Join-Path $artifacts "$Name.key")
        knownHostsPath = (Join-Path $artifacts 'known_hosts'); ownershipId = [guid]::NewGuid().ToString()
        publicIp = ''; vmName = "$Name-vm"; workspaceId = ''; workspaceName = "$Name-logs"
        workspaceCustomerId = ''; pipelineId = ''; pipelineName = "$Name-pipeline"
        pipelineVersion = $PipelineVersion; pipelineReleaseTrain = $PipelineReleaseTrain
        certificateVersion = $CertificateVersion; customLocationId = ''; endpointUrl = ''; ruleId = ''
        useRunCommand = [bool]$UseRunCommand
    }
    Save-DemoJson $state $StatePath
}
Assert-DemoManagementAccess $state.useRunCommand $AdminCidr
foreach ($property in @('customLocationsOid','bootstrapRoleId')) {
    if (-not $state.PSObject.Properties[$property]) { $state | Add-Member $property '' }
}
if (-not $CustomLocationsOid -and $state.customLocationsOid) { $CustomLocationsOid = $state.customLocationsOid }
if (-not $CustomLocationsOid) {
    try {
        $CustomLocationsOid = (Invoke-Azure @('ad','sp','show','--id','bc313c14-388c-4e7d-a58e-70017303ee3b')).id
    } catch {
        throw "Cannot read the tenant's Custom Locations service-principal object ID. Ask a tenant administrator to run: az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query id -o tsv; then pass -CustomLocationsOid. No new infrastructure was deployed by this invocation. Original error: $($_.Exception.Message)"
    }
}
$state.customLocationsOid = $CustomLocationsOid
Save-DemoJson $state $StatePath
if (-not (Test-Path $state.keyPath)) {
    Invoke-Native ssh-keygen @('-q', '-t', 'ed25519', '-N', '', '-f', $state.keyPath)
}
$exists = Invoke-Azure @('group', 'exists', '--name', $state.resourceGroup, '--subscription', $SubscriptionId)
if ($exists) {
    $group = Invoke-Azure @('group', 'show', '--name', $state.resourceGroup, '--subscription', $SubscriptionId)
    if ($group.tags.demoOwnershipId -ne $state.ownershipId) { throw 'Refusing to use a resource group not owned by this state.' }
    Remove-DemoBootstrapRole $state
    $state.bootstrapRoleId = ''
    Save-DemoJson $state $StatePath
} else {
    Invoke-Azure @('group', 'create', '--name', $state.resourceGroup, '--location', 'westeurope',
        '--subscription', $SubscriptionId, '--tags', "demoOwnershipId=$($state.ownershipId)", 'application=azure-monitor-pipeline-demo') | Out-Null
}
$registrations = @(Invoke-Azure @('provider','list','--subscription',$SubscriptionId,'--query','[].{namespace:namespace,registrationState:registrationState}'))
foreach ($provider in @('Microsoft.Compute','Microsoft.Network','Microsoft.OperationalInsights','Microsoft.OperationsManagement',
        'Microsoft.SecurityInsights','Microsoft.Kubernetes','Microsoft.KubernetesConfiguration','Microsoft.ExtendedLocation','Microsoft.Insights','Microsoft.Monitor')) {
    $registration = $registrations | Where-Object namespace -eq $provider
    if ($registration.registrationState -ne 'Registered') {
        Invoke-Azure @('provider', 'register', '--namespace', $provider, '--wait', '--subscription', $SubscriptionId) | Out-Null
    }
}
$outputs = Invoke-DemoDeployment $state 'foundation' @{
    name = $Name; adminCidr = $AdminCidr; sshPublicKey = (Get-Content "$($state.keyPath).pub" -Raw).Trim(); vmSize = $VmSize
    useRunCommand = $state.useRunCommand
}
foreach ($property in @('publicIp','vmName','workspaceId','workspaceName','workspaceCustomerId')) {
    $state.$property = $outputs.$property.value
}
Save-DemoJson $state $StatePath
if (-not $state.useRunCommand) {
    $ready = $false
    for ($attempt = 0; $attempt -lt 6; $attempt++) {
        & ssh @(Get-SshArguments $state) "demoadmin@$($state.publicIp)" true
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 10
    }
    if (-not $ready) { throw 'SSH not ready. Check AdminCidr or rerun with UseRunCommand.' }
}
Copy-DemoSources $state $root
Invoke-DemoSsh $state 'sudo bash /home/demoadmin/demo/scripts/linux/bootstrap.sh' | Out-Host
$kubePath = Join-Path $artifacts 'cluster.kubeconfig'
$tunnel = $null
try {
    if ($state.useRunCommand) {
        $scope = "/subscriptions/$SubscriptionId/resourceGroups/$($state.resourceGroup)"
        $assignmentName = [guid]::NewGuid().ToString()
        $state.bootstrapRoleId = "$scope/providers/Microsoft.Authorization/roleAssignments/$assignmentName"
        Save-DemoJson $state $StatePath
        try {
            Invoke-Azure @('role','assignment','create','--name',$assignmentName,'--assignee-object-id',$outputs.vmPrincipalId.value,
                '--assignee-principal-type','ServicePrincipal','--role','34e09817-6cbe-4d01-b1a2-e0eac5743d41',
                '--scope',$scope,'--subscription',$SubscriptionId) | Out-Null
            Invoke-DemoSsh $state "sudo bash /home/demoadmin/demo/scripts/linux/connect-arc.sh '$SubscriptionId' '$($state.resourceGroup)' '$Name-arc' '$CustomLocationsOid'" | Out-Host
        } finally {
            Remove-DemoBootstrapRole $state
            $state.bootstrapRoleId = ''
            Save-DemoJson $state $StatePath
        }
    } else {
    $kubeconfig = (Invoke-DemoSsh $state 'sudo cat /etc/rancher/k3s/k3s.yaml') -join "`n"
    $kubeconfig.Replace('127.0.0.1:6443','127.0.0.1:16443') | Set-Content $kubePath -Encoding utf8NoBOM
    $start = [Diagnostics.ProcessStartInfo]::new('ssh')
    $start.UseShellExecute = $false
    foreach ($arg in ((Get-SshArguments $state) + @('-o','ExitOnForwardFailure=yes','-N','-L',
                '127.0.0.1:16443:127.0.0.1:6443',"demoadmin@$($state.publicIp)"))) { $start.ArgumentList.Add($arg) }
    $tunnel = [Diagnostics.Process]::Start($start)
    Start-Sleep -Seconds 2
    if ($tunnel.HasExited) { throw 'Kubernetes SSH tunnel could not start.' }
    Invoke-Native kubectl @('--kubeconfig', $kubePath, 'get', 'nodes') | Out-Host
    Invoke-Azure @('connectedk8s','connect','--name',"$Name-arc",'--resource-group',$state.resourceGroup,
        '--location','westeurope','--kube-config',$kubePath,'--subscription',$SubscriptionId) | Out-Null
    Invoke-Azure @('connectedk8s','enable-features','--name',"$Name-arc",'--resource-group',$state.resourceGroup,
        '--features','cluster-connect','custom-locations','--custom-locations-oid',$CustomLocationsOid,
        '--kube-config',$kubePath,'--subscription',$SubscriptionId) | Out-Null
    }
    $common = @('--cluster-name',"$Name-arc",'--resource-group',$state.resourceGroup,'--cluster-type','connectedClusters',
        '--subscription',$SubscriptionId)
    $extensions = @(Invoke-Azure (@('k8s-extension','list') + $common))
    $certificate = $extensions | Where-Object name -eq 'azure-cert-management'
    if (-not $certificate) {
        $certificateArgs = @('k8s-extension','create','--name','azure-cert-management','--extension-type','microsoft.certmanagement','--release-train','Stable')
        if ($CertificateVersion) { $certificateArgs += @('--version',$CertificateVersion,'--auto-upgrade-mode','none') }
        $certificate = Invoke-Azure ($certificateArgs + $common)
    } elseif ($CertificateVersion -and $certificate.version -ne $CertificateVersion) {
        throw 'Installed certificate version differs from recorded version. Refusing an implicit upgrade.'
    }
    if ($certificate.provisioningState -ne 'Succeeded') { throw 'Certificate extension is not healthy.' }
    $state.certificateVersion = $certificate.version
    Invoke-Azure (@('k8s-extension','update','--name','azure-cert-management','--auto-upgrade-mode','none') + $common) | Out-Null
    Save-DemoJson $state $StatePath
    $pipelineExtension = $extensions | Where-Object name -eq 'pipeline-controller'
    if (-not $pipelineExtension) {
        $pipelineExtension = Invoke-Azure (@('k8s-extension','create','--name','pipeline-controller',
            '--extension-type','microsoft.monitor.pipelinecontroller','--version',$PipelineVersion,
            '--release-train',$PipelineReleaseTrain,'--auto-upgrade-mode','none','--scope','cluster','--release-namespace','pipeline-demo') + $common)
    } elseif ($pipelineExtension.version -ne $PipelineVersion -or $pipelineExtension.releaseTrain -ne $PipelineReleaseTrain) {
        throw 'Installed pipeline version/train differs from recorded version. Refusing an implicit upgrade.'
    }
    if ($pipelineExtension.provisioningState -ne 'Succeeded') { throw 'Pipeline extension is not healthy.' }
    # Extension provisioning can succeed while its managed certificate issuers are unready.
    Invoke-DemoSsh $state @'
if ! sudo k3s kubectl wait --for=condition=Ready clusterissuer arc-amp-root-ca-cluster-issuer arc-amp-client-root-ca-cluster-issuer --timeout=180s; then
    sudo k3s kubectl get clusterissuer arc-amp-root-ca-cluster-issuer arc-amp-client-root-ca-cluster-issuer -o json | jq '[.items[] | {name:.metadata.name,conditions:.status.conditions}]'
    echo 'Pipeline certificate issuers are not Ready; stopping before pipeline resource creation.' >&2
    exit 1
fi
'@ | Out-Host
    $cluster = Invoke-Azure @('connectedk8s','show','--name',"$Name-arc",'--resource-group',$state.resourceGroup,'--subscription',$SubscriptionId)
    $custom = Invoke-Azure @('customlocation','create','--name',"$Name-location",'--resource-group',$state.resourceGroup,
        '--namespace','pipeline-demo','--host-resource-id',$cluster.id,'--cluster-extension-ids',$pipelineExtension.id,
        '--location','westeurope','--subscription',$SubscriptionId)
    $state.customLocationId = $custom.id
    $collection = Invoke-DemoDeployment $state 'collection' @{
        name = $Name; workspaceName = $state.workspaceName; extensionPrincipalId = $pipelineExtension.identity.principalId
    }
    $state.endpointUrl = $collection.endpointUrl.value
    $state.ruleId = $collection.ruleId.value
    Save-DemoJson $state $StatePath
    $pipeline = Invoke-DemoDeployment $state 'pipeline' @{
        name = $Name; customLocationId = $state.customLocationId; endpointUrl = $state.endpointUrl
        ruleId = $state.ruleId; workspaceName = $state.workspaceName
    }
    $state.pipelineId = $pipeline.pipelineId.value
    Save-DemoJson $state $StatePath
    Invoke-DemoSsh $state "sudo bash /home/demoadmin/demo/scripts/linux/gateway.sh $($state.pipelineName)" | Out-Host
} finally {
    if ($tunnel -and -not $tunnel.HasExited) { Stop-Process -Id $tunnel.Id }
}
& "$PSScriptRoot\Test-Demo.ps1" -StatePath $StatePath -Scene Ingestion
Write-Output $StatePath
