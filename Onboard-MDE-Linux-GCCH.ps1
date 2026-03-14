<#
.SYNOPSIS
    Onboard Linux VMs in Azure Commercial to MDE GCC High tenant
.DESCRIPTION
    Enumerates Linux VMs in target resource group, downloads Gov onboarding JSON,
    installs MDE for Linux, validates mdatp health, logs results
.PARAMETER SubscriptionId
    Azure subscription ID containing target VMs
.PARAMETER ResourceGroupName
    Resource group containing target VMs
.PARAMETER OnboardingJsonUrl
    Blob URL for mdatp_onboard.json (Gov tenant package)
.PARAMETER StorageAccountName
    Storage account for deployment logs
.PARAMETER StorageContainerName
    Container for deployment logs
.NOTES
    Target: GCC High MDE tenant (ugobami.onmicrosoft.us)
    Managed Identity: bc4eff3e-ddf0-4a40-9bbf-311bce412071
    Supports: Ubuntu, RHEL, CentOS, Debian, SUSE
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId = "d5de391c-9572-4dab-8610-32a41b3a860c",

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName = "Knightsmgmt01_group",

    [Parameter(Mandatory = $true)]
    [string]$OnboardingJsonUrl = "https://teststrgaccount.blob.core.windows.net/mde/mdatp_onboard.json",

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

# Get all Linux VMs in resource group
Write-Output "`nEnumerating Linux VMs in resource group: $ResourceGroupName"
$vms = Get-AzVM -ResourceGroupName $ResourceGroupName -Status | Where-Object {
    $_.StorageProfile.OsDisk.OsType -eq 'Linux' -and
    $_.PowerState -eq 'VM running'
}

if ($vms.Count -eq 0) {
    Write-Warning "No running Linux VMs found in resource group."
    exit 0
}

Write-Output "Found $($vms.Count) running Linux VM(s):"
$vms | ForEach-Object { Write-Output "  - $($_.Name) [$($_.Location)]" }

# Results tracking
$results = @()
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

# Linux onboarding script (universal for all distros)
$onboardingCommand = @'
#!/bin/bash
set -e

echo "=== MDE for Linux Onboarding Script - GCC High ==="
ONBOARDING_URL="{{ONBOARDING_URL}}"
TEMP_DIR="/tmp/mde-onboard"
ONBOARDING_JSON="$TEMP_DIR/mdatp_onboard.json"

# Detect distro
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO=$ID
    VERSION_ID=$VERSION_ID
else
    echo "ERROR: Cannot detect Linux distribution"
    exit 1
fi

echo "Detected: $DISTRO $VERSION_ID"

# Create temp directory
mkdir -p "$TEMP_DIR"

# Download onboarding JSON
echo "Downloading onboarding package..."
if command -v curl &> /dev/null; then
    curl -sSL "$ONBOARDING_URL" -o "$ONBOARDING_JSON"
elif command -v wget &> /dev/null; then
    wget -q "$ONBOARDING_URL" -O "$ONBOARDING_JSON"
else
    echo "ERROR: Neither curl nor wget available"
    exit 1
fi

if [ ! -f "$ONBOARDING_JSON" ]; then
    echo "ERROR: Failed to download onboarding JSON"
    exit 1
fi

# Add Microsoft repository and install mdatp based on distro
case "$DISTRO" in
    ubuntu|debian)
        echo "Installing for Debian/Ubuntu..."
        
        # Add Microsoft GPG key
        curl -sSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /tmp/microsoft.gpg
        install -o root -g root -m 644 /tmp/microsoft.gpg /etc/apt/trusted.gpg.d/
        rm /tmp/microsoft.gpg
        
        # Add repository
        if [ "$DISTRO" = "ubuntu" ]; then
            echo "deb [arch=amd64,arm64,armhf] https://packages.microsoft.com/ubuntu/$VERSION_ID/prod $VERSION_ID main" > /etc/apt/sources.list.d/microsoft-prod.list
        else
            echo "deb [arch=amd64,arm64,armhf] https://packages.microsoft.com/debian/$VERSION_ID/prod $VERSION_ID main" > /etc/apt/sources.list.d/microsoft-prod.list
        fi
        
        apt-get update -qq
        apt-get install -y mdatp
        ;;
        
    rhel|centos|almalinux|rocky)
        echo "Installing for RHEL/CentOS..."
        
        # Add repository
        if [ "${VERSION_ID%%.*}" -ge 8 ]; then
            dnf config-manager --add-repo=https://packages.microsoft.com/config/rhel/8/prod.repo
            dnf install -y mdatp
        else
            yum-config-manager --add-repo=https://packages.microsoft.com/config/rhel/7/prod.repo
            yum install -y mdatp
        fi
        ;;
        
    sles|opensuse*)
        echo "Installing for SUSE..."
        
        zypper addrepo -G -f https://packages.microsoft.com/config/sles/15/prod.repo
        zypper refresh
        zypper install -y mdatp
        ;;
        
    *)
        echo "ERROR: Unsupported distribution: $DISTRO"
        exit 1
        ;;
esac

# Onboard using JSON
echo "Onboarding to MDE GCC High tenant..."
mdatp health --field org_id > /dev/null 2>&1 || true
python3 /opt/microsoft/mdatp/sbin/install.py --onboard "$ONBOARDING_JSON" || \
python /opt/microsoft/mdatp/sbin/install.py --onboard "$ONBOARDING_JSON" || \
mdatp config onboarding --file "$ONBOARDING_JSON"

# Wait for service to stabilize
sleep 5

# Validate health
echo "Validating MDE health..."
HEALTH_STATUS=$(mdatp health --field healthy || echo "false")
ORG_ID=$(mdatp health --field org_id 2>/dev/null || echo "unknown")

if [ "$HEALTH_STATUS" = "true" ] && [ "$ORG_ID" != "unknown" ]; then
    echo "SUCCESS: MDE is healthy and onboarded"
    echo "Org ID: $ORG_ID"
    exit 0
else
    echo "WARNING: MDE installed but health check incomplete"
    mdatp health
    exit 1
fi
'@

# Process each Linux VM
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
        MDEHealth      = "Unknown"
    }

    try {
        # Inject URL into script
        $scriptToRun = $onboardingCommand -replace '{{ONBOARDING_URL}}', $OnboardingJsonUrl

        # Execute Run Command
        $runCommandResult = Invoke-AzVMRunCommand `
            -ResourceGroupName $ResourceGroupName `
            -VMName $vm.Name `
            -CommandId 'RunShellScript' `
            -ScriptString $scriptToRun `
            -ErrorAction Stop

        $output = $runCommandResult.Value[0].Message
        Write-Output $output

        if ($output -match "SUCCESS: MDE is healthy and onboarded") {
            $result.Status = "Success"
            $result.Message = "MDE for Linux onboarded successfully"
            $result.MDEHealth = "Healthy"
            Write-Output "[$($vm.Name)] ✓ SUCCESS"
        }
        elseif ($output -match "WARNING: MDE installed but health check incomplete") {
            $result.Status = "PartialSuccess"
            $result.Message = "MDE installed but health validation incomplete"
            $result.MDEHealth = "Partial"
            Write-Output "[$($vm.Name)] ⚠ PARTIAL SUCCESS"
        }
        else {
            $result.Status = "Failed"
            $result.Message = "Onboarding script execution failed"
            $result.MDEHealth = "Failed"
            Write-Output "[$($vm.Name)] ✗ FAILED"
        }
    }
    catch {
        $result.Status = "Failed"
        $result.Message = "Run Command execution failed: $($_.Exception.Message)"
        $result.MDEHealth = "Failed"
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
$results | Format-Table -AutoSize VMName, Status, Message, MDEHealth

# Export results to blob storage
try {
    $reportFileName = "mde-onboarding-linux-$timestamp.json"
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
