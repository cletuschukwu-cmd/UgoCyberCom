<#
.SYNOPSIS
    Onboard Windows VMs in Azure Commercial to MDE GCC High tenant
.DESCRIPTION
    Enumerates Windows VMs in target resource group, downloads Gov onboarding script,
    executes via Run Command, validates sensor status, logs results
.PARAMETER SubscriptionId
    Azure subscription ID containing target VMs
.PARAMETER ResourceGroupName
    Resource group containing target VMs
.PARAMETER OnboardingScriptUrl
    Blob URL for WindowsDefenderATPLocalOnboardingScript.cmd (Gov tenant package)
.PARAMETER StorageAccountName
    Storage account for deployment logs
.PARAMETER StorageContainerName
    Container for deployment logs
.NOTES
    Target: GCC High MDE tenant (ugobami.onmicrosoft.us)
    Managed Identity: bc4eff3e-ddf0-4a40-9bbf-311bce412071
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId = "d5de391c-9572-4dab-8610-32a41b3a860c",

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName = "Knightsmgmt01_group",

    [Parameter(Mandatory = $true)]
    [string]$OnboardingScriptUrl = "https://teststrgaccount.blob.core.windows.net/mde/WindowsDefenderATPLocalOnboardingScript.cmd",

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

# Download onboarding script from blob storage using managed identity
Write-Output "`nDownloading MDE onboarding script from blob storage..."
try {
    # Parse blob URL
    $uri = [System.Uri]$OnboardingScriptUrl
    $storageAccountName = $uri.Host.Split('.')[0]
    $pathParts = $uri.AbsolutePath.TrimStart('/').Split('/')
    $containerName = $pathParts[0]
    $blobName = $pathParts[1..($pathParts.Length-1)] -join '/'
    
    Write-Output "  Storage Account: $storageAccountName"
    Write-Output "  Container: $containerName"
    Write-Output "  Blob: $blobName"
    
    # Get OAuth token from IMDS for storage
    $tokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://storage.azure.com/"
    $tokenResponse = Invoke-RestMethod -Uri $tokenUri -Method GET -Headers @{Metadata="true"}
    $accessToken = $tokenResponse.access_token
    Write-Output "  ✓ Acquired storage access token"
    
    # Download blob using REST API
    $blobUrl = "https://$storageAccountName.blob.core.windows.net/$containerName/$blobName"
    $headers = @{
        "Authorization" = "Bearer $accessToken"
        "x-ms-version" = "2021-08-06"
    }
    
    Write-Output "  Downloading from: $blobUrl"
    $webClient = New-Object System.Net.WebClient
    $webClient.Headers.Add("Authorization", "Bearer $accessToken")
    $webClient.Headers.Add("x-ms-version", "2021-08-06")
    $scriptBytes = $webClient.DownloadData($blobUrl)
    $webClient.Dispose()
    
    # Base64 encode for transmission to VMs
    $scriptBase64 = [Convert]::ToBase64String($scriptBytes)
    
    Write-Output "✓ Successfully downloaded onboarding script ($($scriptBytes.Length) bytes)"
}
catch {
    Write-Error "Failed to download onboarding script: $($_.Exception.Message)"
    Write-Error "Details: $($_.Exception.InnerException.Message)"
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

# Onboarding script to execute on each VM
$onboardingCommand = @"
# Decode and save Gov MDE onboarding script
`$scriptPath = "C:\Temp\WindowsDefenderATPLocalOnboardingScript.cmd"
`$null = New-Item -ItemType Directory -Path "C:\Temp" -Force

try {
    # Decode base64 script content
    `$scriptBytes = [Convert]::FromBase64String('$scriptBase64')
    [System.IO.File]::WriteAllBytes(`$scriptPath, `$scriptBytes)
    
    if (-not (Test-Path `$scriptPath)) {
        throw "Failed to save onboarding script"
    }

    # Execute onboarding script
    Write-Output "Executing MDE onboarding script..."
    `$process = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"`$scriptPath`"" -Wait -PassThru -NoNewWindow
    
    if (`$process.ExitCode -ne 0) {
        throw "Onboarding script exited with code: `$(`$process.ExitCode)"
    }

    # Validate SENSE service
    Start-Sleep -Seconds 10
    `$senseService = Get-Service -Name 'SENSE' -ErrorAction SilentlyContinue
    
    if (`$senseService -and `$senseService.Status -eq 'Running') {
        Write-Output "SUCCESS: MDE sensor (SENSE) is running"
        exit 0
    } else {
        Write-Output "WARNING: SENSE service not running yet (may need reboot)"
        exit 1
    }
}
catch {
    Write-Error "FAILED: `$_"
    exit 2
}
finally {
    # Cleanup
    Remove-Item -Path `$scriptPath -Force -ErrorAction SilentlyContinue
}
"@

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
        # Execute Run Command
        $runCommandResult = Invoke-AzVMRunCommand `
            -ResourceGroupName $ResourceGroupName `
            -VMName $vm.Name `
            -CommandId 'RunPowerShellScript' `
            -ScriptString $onboardingCommand `
            -ErrorAction Stop

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
        $result.Status = "Failed"
        $result.Message = "Run Command execution failed: $($_.Exception.Message)"
        Write-Error "[$($vm.Name)] ✗ FAILED: $_"
    }

    $results += $result
}

# Generate summary report
Write-Output "`n=== Onboarding Summary ==="
$successCount = ($results | Where-Object { $_.Status -eq 'Success' }).Count
$partialCount = ($results | Where-Object { $_.Status -eq 'PartialSuccess' }).Count
$failedCount = ($results | Where-Object { $_.Status -eq 'Failed' }).Count

Write-Output "Total VMs processed: $($results.Count)"
Write-Output "✓ Success: $successCount"
Write-Output "⚠ Partial: $partialCount"
Write-Output "✗ Failed: $failedCount"

Write-Output "`nDetailed Results:"
$results | Format-Table -AutoSize VMName, Status, Message, SenseDetected

# Export results to blob storage
try {
    $reportFileName = "mde-onboarding-windows-$timestamp.json"
    $reportPath = "$env:TEMP\$reportFileName"
    $results | ConvertTo-Json -Depth 5 | Out-File -FilePath $reportPath -Encoding UTF8
    
    Write-Output "`nUploading results to Storage Account..."
    $storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction SilentlyContinue
    
    if ($storageAccount) {
        $ctx = $storageAccount.Context
        
        # Ensure container exists
        $container = Get-AzStorageContainer -Name $StorageContainerName -Context $ctx -ErrorAction SilentlyContinue
        if (-not $container) {
            New-AzStorageContainer -Name $StorageContainerName -Context $ctx -Permission Off | Out-Null
            Write-Output "Created container: $StorageContainerName"
        }
        
        Set-AzStorageBlobContent -File $reportPath -Container $StorageContainerName -Blob $reportFileName -Context $ctx -Force | Out-Null
        Write-Output "✓ Results uploaded: $reportFileName"
    }
    else {
        Write-Warning "Storage account not found - skipping upload"
    }
}
catch {
    Write-Warning "Failed to upload results to storage: $_"
}

Write-Output "`n=== Runbook Completed ==="
