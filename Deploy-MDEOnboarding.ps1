<#
.SYNOPSIS
    Deploy MDE GCC High onboarding runbooks to Azure Automation Account
.DESCRIPTION
    Validates prerequisites, uploads runbooks, and optionally starts onboarding jobs
.PARAMETER AutomationAccountName
    Name of the Azure Automation Account
.PARAMETER ExecuteImmediately
    If specified, starts onboarding jobs immediately after deployment
.NOTES
    Run this script with appropriate Azure RBAC permissions
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AutomationAccountName,

    [Parameter(Mandatory = $true)]
    [string]$AutomationResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$VMResourceGroup,

    [Parameter(Mandatory = $false)]
    [switch]$ExecuteImmediately
)

$ErrorActionPreference = 'Stop'

# Configuration
$subscriptionId = "d5de391c-9572-4dab-8610-32a41b3a860c"
$windowsScriptUrl = "https://teststrgaccount.blob.core.windows.net/mde/WindowsDefenderATPLocalOnboardingScript.cmd"
$linuxScriptUrl = "https://teststrgaccount.blob.core.windows.net/mde/mdatp_onboard.json"
$storageAccount = "teststrgaccount"
$logContainer = "mde-logs"
$managedIdentityId = "bc4eff3e-ddf0-4a40-9bbf-311bce412071"

Write-Host "`n=== MDE GCC High Onboarding Deployment ===" -ForegroundColor Cyan
Write-Host "Target: ugobami.onmicrosoft.us (GCC High)`n"

# Step 1: Connect to Azure
Write-Host "[1/6] Connecting to Azure..." -ForegroundColor Yellow
try {
    $context = Get-AzContext
    if (-not $context -or $context.Subscription.Id -ne $subscriptionId) {
        Connect-AzAccount | Out-Null
        Set-AzContext -SubscriptionId $subscriptionId | Out-Null
    }
    Write-Host "  ✓ Connected to subscription: $($context.Subscription.Name)" -ForegroundColor Green
}
catch {
    Write-Error "Failed to connect to Azure: $_"
    exit 1
}

# Step 2: Verify Automation Account
Write-Host "`n[2/6] Validating Automation Account..." -ForegroundColor Yellow
try {
    $automationAccount = Get-AzAutomationAccount -ResourceGroupName $AutomationResourceGroup -Name $AutomationAccountName -ErrorAction Stop
    Write-Host "  ✓ Found Automation Account: $($automationAccount.AutomationAccountName)" -ForegroundColor Green
    Write-Host "    Location: $($automationAccount.Location)" -ForegroundColor Gray
    Write-Host "    Identity: $($automationAccount.Identity.Type)" -ForegroundColor Gray
    
    if ($automationAccount.Identity.Type -ne 'SystemAssigned' -and $automationAccount.Identity.Type -ne 'SystemAssigned, UserAssigned') {
        Write-Warning "  ⚠ System-assigned managed identity not enabled. Enable it in Azure portal."
    }
}
catch {
    Write-Error "Automation Account '$AutomationAccountName' not found in resource group '$AutomationResourceGroup'"
    exit 1
}

# Step 3: Verify RBAC permissions
Write-Host "`n[3/6] Checking managed identity permissions..." -ForegroundColor Yellow
try {
    $roleAssignments = Get-AzRoleAssignment -ObjectId $managedIdentityId -Scope "/subscriptions/$subscriptionId/resourceGroups/$VMResourceGroup"
    
    $hasVMContributor = $roleAssignments | Where-Object { $_.RoleDefinitionName -match 'Contributor|Virtual Machine Contributor' }
    
    if ($hasVMContributor) {
        Write-Host "  ✓ VM permissions: OK" -ForegroundColor Green
    } else {
        Write-Warning "  ⚠ Missing 'Virtual Machine Contributor' role - onboarding may fail"
        Write-Host "    Run: New-AzRoleAssignment -ObjectId $managedIdentityId -RoleDefinitionName 'Virtual Machine Contributor' -Scope '/subscriptions/$subscriptionId/resourceGroups/$VMResourceGroup'" -ForegroundColor Gray
    }
}
catch {
    Write-Warning "  ⚠ Could not verify RBAC permissions: $_"
}

# Step 4: Check onboarding artifacts
Write-Host "`n[4/6] Verifying onboarding artifacts..." -ForegroundColor Yellow

# Check Windows script
try {
    $windowsTest = Invoke-WebRequest -Uri $windowsScriptUrl -Method Head -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    Write-Host "  ✓ Windows script accessible: $windowsScriptUrl" -ForegroundColor Green
}
catch {
    Write-Warning "  ⚠ Windows script not accessible: $windowsScriptUrl"
    Write-Warning "    Error: $($_.Exception.Message)"
    Write-Host "    Ensure blob has public read access or append SAS token to URL" -ForegroundColor Gray
}

# Check Linux JSON
try {
    $linuxTest = Invoke-WebRequest -Uri $linuxScriptUrl -Method Head -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    Write-Host "  ✓ Linux JSON accessible: $linuxScriptUrl" -ForegroundColor Green
}
catch {
    Write-Warning "  ⚠ Linux JSON not accessible: $linuxScriptUrl"
    Write-Warning "    You must upload mdatp_onboard.json from GCC High portal"
    Write-Host "    Download from: https://security.microsoft.us → Settings → Endpoints → Onboarding → Linux Server" -ForegroundColor Gray
}

# Step 5: Import runbooks
Write-Host "`n[5/6] Importing runbooks to Automation Account..." -ForegroundColor Yellow

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path

# Import Windows runbook
try {
    $windowsRunbookPath = Join-Path $scriptPath "Onboard-MDE-Windows-GCCH.ps1"
    if (-not (Test-Path $windowsRunbookPath)) {
        throw "Windows runbook not found at: $windowsRunbookPath"
    }
    
    Import-AzAutomationRunbook `
        -ResourceGroupName $AutomationResourceGroup `
        -AutomationAccountName $AutomationAccountName `
        -Path $windowsRunbookPath `
        -Type PowerShell `
        -Name "Onboard-MDE-Windows-GCCH" `
        -Force `
        -ErrorAction Stop | Out-Null
    
    Publish-AzAutomationRunbook `
        -ResourceGroupName $AutomationResourceGroup `
        -AutomationAccountName $AutomationAccountName `
        -Name "Onboard-MDE-Windows-GCCH" `
        -ErrorAction Stop | Out-Null
    
    Write-Host "  ✓ Windows runbook imported and published" -ForegroundColor Green
}
catch {
    Write-Error "Failed to import Windows runbook: $_"
}

# Import Linux runbook
try {
    $linuxRunbookPath = Join-Path $scriptPath "Onboard-MDE-Linux-GCCH.ps1"
    if (-not (Test-Path $linuxRunbookPath)) {
        throw "Linux runbook not found at: $linuxRunbookPath"
    }
    
    Import-AzAutomationRunbook `
        -ResourceGroupName $AutomationResourceGroup `
        -AutomationAccountName $AutomationAccountName `
        -Path $linuxRunbookPath `
        -Type PowerShell `
        -Name "Onboard-MDE-Linux-GCCH" `
        -Force `
        -ErrorAction Stop | Out-Null
    
    Publish-AzAutomationRunbook `
        -ResourceGroupName $AutomationResourceGroup `
        -AutomationAccountName $AutomationAccountName `
        -Name "Onboard-MDE-Linux-GCCH" `
        -ErrorAction Stop | Out-Null
    
    Write-Host "  ✓ Linux runbook imported and published" -ForegroundColor Green
}
catch {
    Write-Error "Failed to import Linux runbook: $_"
}

# Step 6: Optionally start jobs
if ($ExecuteImmediately) {
    Write-Host "`n[6/6] Starting onboarding jobs..." -ForegroundColor Yellow
    
    # Start Windows job
    try {
        $windowsJob = Start-AzAutomationRunbook `
            -ResourceGroupName $AutomationResourceGroup `
            -AutomationAccountName $AutomationAccountName `
            -Name "Onboard-MDE-Windows-GCCH" `
            -Parameters @{
                SubscriptionId = $subscriptionId
                ResourceGroupName = $VMResourceGroup
                OnboardingScriptUrl = $windowsScriptUrl
                StorageAccountName = $storageAccount
                StorageContainerName = $logContainer
            } `
            -ErrorAction Stop
        
        Write-Host "  ✓ Windows onboarding job started" -ForegroundColor Green
        Write-Host "    Job ID: $($windowsJob.JobId)" -ForegroundColor Gray
        Write-Host "    Monitor: https://portal.azure.com/#@ugobami.onmicrosoft.us/resource/subscriptions/$subscriptionId/resourceGroups/$AutomationResourceGroup/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/jobs/$($windowsJob.JobId)/overview" -ForegroundColor Gray
    }
    catch {
        Write-Warning "  ⚠ Failed to start Windows job: $_"
    }
    
    # Start Linux job
    try {
        $linuxJob = Start-AzAutomationRunbook `
            -ResourceGroupName $AutomationResourceGroup `
            -AutomationAccountName $AutomationAccountName `
            -Name "Onboard-MDE-Linux-GCCH" `
            -Parameters @{
                SubscriptionId = $subscriptionId
                ResourceGroupName = $VMResourceGroup
                OnboardingJsonUrl = $linuxScriptUrl
                StorageAccountName = $storageAccount
                StorageContainerName = $logContainer
            } `
            -ErrorAction Stop
        
        Write-Host "  ✓ Linux onboarding job started" -ForegroundColor Green
        Write-Host "    Job ID: $($linuxJob.JobId)" -ForegroundColor Gray
        Write-Host "    Monitor: https://portal.azure.com/#@ugobami.onmicrosoft.us/resource/subscriptions/$subscriptionId/resourceGroups/$AutomationResourceGroup/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/jobs/$($linuxJob.JobId)/overview" -ForegroundColor Gray
    }
    catch {
        Write-Warning "  ⚠ Failed to start Linux job: $_"
    }
} else {
    Write-Host "`n[6/6] Skipping immediate execution (use -ExecuteImmediately to auto-start)" -ForegroundColor Yellow
}

Write-Host "`n=== Deployment Complete ===" -ForegroundColor Cyan
Write-Host "`nNext steps:" -ForegroundColor White
Write-Host "1. Ensure Linux onboarding JSON is uploaded: $linuxScriptUrl" -ForegroundColor Gray
Write-Host "2. Start jobs manually from Azure portal or run:" -ForegroundColor Gray
Write-Host "   Start-AzAutomationRunbook -ResourceGroupName '$AutomationResourceGroup' -AutomationAccountName '$AutomationAccountName' -Name 'Onboard-MDE-Windows-GCCH'" -ForegroundColor DarkGray
Write-Host "   Start-AzAutomationRunbook -ResourceGroupName '$AutomationResourceGroup' -AutomationAccountName '$AutomationAccountName' -Name 'Onboard-MDE-Linux-GCCH'" -ForegroundColor DarkGray
Write-Host "3. Monitor results in GCC High portal: https://security.microsoft.us" -ForegroundColor Gray
Write-Host "4. Check logs in storage: https://$storageAccount.blob.core.windows.net/$logContainer/`n" -ForegroundColor Gray
