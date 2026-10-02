#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Native {
    param([string]$Command, [string[]]$Arguments)
    $stderrPath = [IO.Path]::GetTempFileName()
    try {
        if ($Command -eq 'az' -and $IsWindows) {
            # Bypass az.cmd: cmd.exe otherwise reinterprets JSON, &, and KQL operators.
            $cliPython = Join-Path (Split-Path (Split-Path (Get-Command az).Source)) 'python.exe'
            & $cliPython -IBm azure.cli @Arguments 2>$stderrPath
        } else {
            & $Command @Arguments 2>$stderrPath
        }
        $code = $LASTEXITCODE
        $diagnostic = Get-Content $stderrPath -Raw
        if ($code -ne 0) { throw "$Command failed with exit code ${code}: $diagnostic" }
        if ($diagnostic) { Write-Verbose $diagnostic }
    } finally {
        Remove-Item $stderrPath
    }
}

function Invoke-Azure {
    param([string[]]$Arguments)
    $result = Invoke-Native az ($Arguments + @('--only-show-errors', '--output', 'json'))
    if ($result) { ($result -join "`n") | ConvertFrom-Json }
}

function Read-DemoState {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "No deployment state at $Path. Run Deploy-Demo.ps1 first." }
    Get-Content $Path -Raw | ConvertFrom-Json
}

function Resolve-DemoVersion {
    param([string]$Name, [string]$Recorded, [string]$Requested, [bool]$Explicit)
    if ($Explicit -and $Recorded -and $Requested -ne $Recorded) {
        throw "Resume cannot change $Name. Drain the buffer and use a separate, explicit upgrade procedure."
    }
    if ($Recorded) { $Recorded } else { $Requested }
}

function Assert-DemoManagementAccess {
    param([bool]$UseRunCommand, [string]$AdminCidr)
    if (-not $UseRunCommand -and $AdminCidr -eq '127.0.0.1/32') {
        throw 'Supply AdminCidr for SSH, or use UseRunCommand for HTTPS-only management.'
    }
}

function Remove-DemoBootstrapRole {
    param($State)
    if (-not $State.bootstrapRoleId) { return }
    $scope = "/subscriptions/$($State.subscriptionId)/resourceGroups/$($State.resourceGroup)"
    if ($State.bootstrapRoleId -notmatch ('^' + [regex]::Escape($scope) + '/providers/Microsoft.Authorization/roleAssignments/[a-f0-9-]{36}$')) {
        throw 'Bootstrap role ID is not in this deployment resource group.'
    }
    $assignments = @(Invoke-Azure @('role','assignment','list','--scope',$scope,'--subscription',$State.subscriptionId))
    if (@($assignments | Where-Object id -eq $State.bootstrapRoleId).Count) {
        Invoke-Azure @('role','assignment','delete','--ids',$State.bootstrapRoleId,'--subscription',$State.subscriptionId) | Out-Null
    }
    $remaining = @(Invoke-Azure @('role','assignment','list','--scope',$scope,'--subscription',$State.subscriptionId))
    if (@($remaining | Where-Object id -eq $State.bootstrapRoleId).Count) { throw 'Bootstrap role cleanup could not be verified.' }
}

function Get-SshArguments {
    param($State)
    @('-i', $State.keyPath, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15',
        '-o', 'StrictHostKeyChecking=accept-new', '-o', "UserKnownHostsFile=$($State.knownHostsPath)")
}

function Invoke-DemoSsh {
    param($State, [string]$Command)
    $Command = $Command.Replace("`r`n", "`n")
    if ($State.PSObject.Properties['useRunCommand'] -and $State.useRunCommand) {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command))
        $token = [guid]::NewGuid().ToString('N')
        $scriptPath = Join-Path $State.artifactsPath "command-$token.sh"
        # Run Command reports provisioning success even when the inner script fails.
        $wrapper = @"
#!/bin/bash
set -uo pipefail
log=/var/tmp/pipeline-demo-$token.log
printf '%s' '$encoded' | base64 -d | bash -euo pipefail >"`$log" 2>&1
code=`$?
echo DEMO_BEGIN_$token
if [ "`$(wc -c < "`$log")" -gt 3000 ]; then echo "Output shortened; full log: `$log"; fi
tail -c 3000 "`$log"
echo
echo DEMO_EXIT_$token=`$code
"@
        try {
            $wrapper.Replace("`r`n","`n") | Set-Content $scriptPath -Encoding utf8NoBOM
            $result = Invoke-Azure @('vm','run-command','invoke','--resource-group',$State.resourceGroup,
                '--name',$State.vmName,'--subscription',$State.subscriptionId,'--command-id','RunShellScript',
                '--scripts',"@$scriptPath")
            $message = ($result.value.message -join "`n")
            if ($message -notmatch "(?s)DEMO_BEGIN_$token\r?\n(.*?)\r?\nDEMO_EXIT_$token=(\d+)") {
                throw "Missing Run Command completion marker. Inspect /var/tmp/pipeline-demo-$token.log on the VM."
            }
            $output = $Matches[1]
            if ([int]$Matches[2] -ne 0) { throw "Remote command failed: $output" }
            if ($output) { $output -split "`n" }
        } finally {
            Remove-Item $scriptPath -ErrorAction SilentlyContinue
        }
    } else {
        Invoke-Native ssh ((Get-SshArguments $State) + @("demoadmin@$($State.publicIp)", $Command))
    }
}

function Copy-DemoSources {
    param($State, [string]$Root)
    if (-not $State.useRunCommand) {
        Invoke-DemoSsh $State 'mkdir -p /home/demoadmin/demo' | Out-Null
        foreach ($folder in @('scripts','kubernetes','simulator')) {
            Invoke-Native scp ((Get-SshArguments $State) + @('-r', (Join-Path $Root $folder), "demoadmin@$($State.publicIp):/home/demoadmin/demo/"))
        }
        return
    }
    $commands = @('mkdir -p /home/demoadmin/demo')
    foreach ($folder in @('scripts','kubernetes','simulator')) {
        foreach ($file in (Get-ChildItem (Join-Path $Root $folder) -File -Recurse |
                Where-Object { $_.Extension -in @('.sh','.yaml','.py') })) {
            $relative = [IO.Path]::GetRelativePath($Root,$file.FullName).Replace('\','/')
            $parent = $relative.Substring(0,$relative.LastIndexOf('/'))
            $content = [IO.File]::ReadAllText($file.FullName).Replace("`r`n","`n")
            $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
            $commands += "mkdir -p '/home/demoadmin/demo/$parent'; printf '%s' '$encoded' | base64 -d > '/home/demoadmin/demo/$relative'"
        }
    }
    Invoke-DemoSsh $State ($commands -join "`n") | Out-Host
}

function Read-DemoRemoteJson {
    param($State, [ValidatePattern('^/home/demoadmin/demo/[a-zA-Z0-9.-]+\.json$')][string]$Path)
    $length = [int]((Invoke-DemoSsh $State "gzip -c '$Path' | base64 -w0 > '$Path.b64'; wc -c < '$Path.b64'") -join '')
    $encoded = [Text.StringBuilder]::new()
    for ($offset = 0; $offset -lt $length; $offset += 2400) {
        $chunk = (Invoke-DemoSsh $State "dd if='$Path.b64' bs=1 skip=$offset count=2400 status=none") -join ''
        if ($chunk.Length -ne [Math]::Min(2400,$length-$offset)) { throw 'Remote JSON transfer was truncated.' }
        [void]$encoded.Append($chunk)
    }
    $inputStream = [IO.MemoryStream]::new([Convert]::FromBase64String($encoded.ToString()))
    $gzip = [IO.Compression.GZipStream]::new($inputStream,[IO.Compression.CompressionMode]::Decompress)
    $reader = [IO.StreamReader]::new($gzip)
    try { $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose(); $gzip.Dispose(); $inputStream.Dispose() }
}

function Invoke-DemoQuery {
    param($State, [string]$Query, [switch]$AllowMissingTable)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            return Invoke-Azure @('monitor', 'log-analytics', 'query', '--workspace', $State.workspaceCustomerId,
                '--analytics-query', $Query, '--timespan', 'PT2H', '--subscription', $State.subscriptionId)
        } catch {
            if ($AllowMissingTable -and $_.Exception.Message -match "(?i)failed to resolve table.*(?:Syslog|CommonSecurityLog|NetworkDemoFiltered_CL|Heartbeat|AzureMetrics)") {
                Write-Verbose "Waiting for first-ingestion table creation: $($_.Exception.Message)"
                return
            }
            if ($attempt -lt 3 -and $_.Exception.Message -match '(?i)ConnectionResetError|Connection aborted|Read timed out') {
                Write-Warning "Log Analytics query transport failed (attempt $attempt of 3); retrying the read: $($_.Exception.Message)"
                Start-Sleep -Seconds (5 * $attempt)
            } else { throw }
        }
    }
}

function Save-DemoJson {
    param($Value, [string]$Path)
    $Value | ConvertTo-Json -Depth 30 | Set-Content -Path $Path -Encoding utf8NoBOM
}

function Invoke-DemoDeployment {
    param($State, [string]$Template, [hashtable]$Parameters)
    $parameterValues = @{}
    foreach ($key in $Parameters.Keys) { $parameterValues[$key] = @{ value = $Parameters[$key] } }
    $parameterFile = Join-Path $State.artifactsPath "$Template.parameters.json"
    Save-DemoJson @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'; parameters = $parameterValues } $parameterFile
    $arguments = @('deployment', 'group', '--resource-group', $State.resourceGroup,
        '--subscription', $State.subscriptionId, '--template-file', (Join-Path $PSScriptRoot "..\infra\$Template.bicep"),
        '--parameters', "@$parameterFile", '--name', $Template)
    Invoke-Native az (@($arguments[0..1]) + @('what-if') + $arguments[2..($arguments.Length - 1)] + @('--only-show-errors')) | Out-Host
    $deployment = Invoke-Azure (@($arguments[0..1]) + @('create') + $arguments[2..($arguments.Length - 1)])
    $deployment.properties.outputs
}
