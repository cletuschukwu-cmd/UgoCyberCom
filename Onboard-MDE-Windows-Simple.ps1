<#
.SYNOPSIS
    Onboard Windows VMs in Azure Commercial to MDE GCC High tenant
.DESCRIPTION
    Simplified version that accepts onboarding script as base64 parameter
.PARAMETER SubscriptionId
    Azure subscription ID containing target VMs
.PARAMETER ResourceGroupName  
    Resource group containing target VMs
.PARAMETER OnboardingScriptBase64
    Base64-encoded WindowsDefenderATPLocalOnboardingScript.cmd content
.PARAMETER StorageAccountName
    Storage account for deployment logs
.PARAMETER StorageContainerName
    Container for deployment logs
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$OnboardingScriptBase64,

    [Parameter(Mandatory = $false)]
    [string]$StorageAccountName = "teststrgaccount",

    [Parameter(Mandatory = $false)]
    [string]$StorageContainerName = "mde-logs"
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Connect using Automation Account System Managed Identity
Write-Output "Connecting to Azure using Managed Identity..."
try {
    Connect-AzAccount -Identity | Out-Null
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    Write-Output "✓ Connected to subscription: $SubscriptionId"
}
catch {
    Write-Error "Failed to authenticate with Managed Identity: $_"
    throw
}

# Get all Windows VMs in resource group
Write-Output "`nEnumerating Windows VMs in resource group: $ResourceGroupName"
$vms = Get-AzVM -ResourceGroupName $ResourceGroupName -Status | Where-Object {
    $_.StorageProfile.OsDisk.OsType -eq 'Windows' -and
    $_.PowerState -eq 'VM running'
}

if ($vms.Count -eq 0) {
    Write-Warning "No running Windows VMs found in resource group."
    exit 0
}

Write-Output "Found $($vms.Count) running Windows VM(s):"
$vms | ForEach-Object { Write-Output "  - $($_.Name) [$($_.Location)]" }

# Results tracking
$results = @()
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

# Execute onboarding on each VM
Write-Output "`n=== Starting MDE Onboarding ==="
foreach ($vm in $vms) {
    Write-Output "`n[$($vm.Name)] Starting onboarding..."
    
    $result = [PSCustomObject]@{
        Timestamp      = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        VMName         = $vm.Name
        ResourceGroup  = $ResourceGroupName
        Location       = $vm.Location
        Status         = "InProgress"
        Message        = ""
        SenseDetected  = $false
    }

    try {
        # Create multi-line PowerShell script as single string
        $vmScriptContent = @"
New-Item -ItemType Directory -Path C:\Temp -Force | Out-Null
[System.Byte[]]`$scriptBytes = [System.Convert]::FromBase64String('$OnboardingScriptBase64')
[System.IO.File]::WriteAllBytes('C:\Temp\mde_onboard.cmd', `$scriptBytes)
`$proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c C:\Temp\mde_onboard.cmd' -Wait -PassThru -NoNewWindow
Start-Sleep -Seconds 12
`$sense = Get-Service -Name 'SENSE' -ErrorAction SilentlyContinue
if (`$sense -and `$sense.Status -eq 'Running') {
    Write-Output 'SUCCESS: MDE sensor is running'
} else {
    Write-Output 'WARNING: SENSE service not detected or not running yet (may require reboot)'
}
Remove-Item -Path 'C:\Temp\mde_onboard.cmd' -Force -ErrorAction SilentlyContinue
"@
        
        # Execute Run Command using older parameter syntax
        $runCommandParams = @{
            ResourceGroupName = $ResourceGroupName
            VMName = $vm.Name
            CommandId = 'RunPowerShellScript'
            ScriptPath = $null
        }
        
        # Write script to temp file
        $tempScript = [System.IO.Path]::GetTempFileName()
        Set-Content -Path $tempScript -Value $vmScriptContent -Encoding UTF8
        $runCommandParams.ScriptPath = $tempScript
        
        $runCommandResult = Invoke-AzVMRunCommand @runCommandParams -ErrorAction Stop
        
        Remove-Item -Path $tempScript -Force -ErrorAction SilentlyContinue

        $output = $runCommandResult.Value[0].Message
        $exitCode = if ($output -match "exit (\d+)") { [int]$matches[1] } else { 0 }

        Write-Output $output

        if ($exitCode -eq 0) {
            $result.Status = "Success"
            $result.Message = "MDE sensor onboarded and running"
            $result.SenseDetected = $true
            Write-Output "[$($vm.Name)] ✓ SUCCESS"
        }
        elseif ($exitCode -eq 1) {
            $result.Status = "PartialSuccess"
            $result.Message = "Onboarding completed but SENSE not running (may need reboot)"
            Write-Output "[$($vm.Name)] ⚠ PARTIAL SUCCESS - reboot may be required"
        }
        else {
            $result.Status = "Failed"
            $result.Message = "Onboarding script failed with exit code $exitCode"
            Write-Output "[$($vm.Name)] ✗ FAILED"
        }
    }
    catch {
        $result.Status = "Error"
        $result.Message = $_.Exception.Message
        Write-Output "[$($vm.Name)] ✗ ERROR: $_"
    }

    $results += $result
}

# Summary
Write-Output "`n=== Onboarding Summary ==="
Write-Output "Total VMs: $($vms.Count)"
Write-Output "Succeeded: $(($results | Where-Object { $_.Status -eq 'Success' }).Count)"
Write-Output "Partial: $(($results | Where-Object { $_.Status -eq 'PartialSuccess' }).Count)"
Write-Output "Failed: $(($results | Where-Object { $_.Status -in @('Failed','Error') }).Count)"

# Upload results to blob storage
try {
    Write-Output "`nUploading results to storage..."
    $resultsJson = $results | ConvertTo-Json -Depth 5
    $resultsBlob = "mde-onboarding-results-$timestamp.json"
    
    # Get OAuth token for storage
    $tokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://storage.azure.com/"
    $tokenResponse = Invoke-RestMethod -Uri $tokenUri -Method GET -Headers @{Metadata="true"}
    $accessToken = $tokenResponse.access_token
    
    # Upload using REST API
    $uploadUrl = "https://$StorageAccountName.blob.core.windows.net/$StorageContainerName/$resultsBlob"
    $body = [System.Text.Encoding]::UTF8.GetBytes($resultsJson)
    
    $uploadHeaders = @{
        "Authorization" = "Bearer $accessToken"
        "x-ms-version" = "2021-08-06"
        "x-ms-blob-type" = "BlockBlob"
        "Content-Type" = "application/json"
    }
    
    Invoke-RestMethod -Uri $uploadUrl -Method PUT -Headers $uploadHeaders -Body $body | Out-Null
    Write-Output "✓ Results uploaded to: $uploadUrl"
}
catch {
    Write-Warning "Failed to upload results: $_"
}

Write-Output "`n✓ Onboarding complete"
