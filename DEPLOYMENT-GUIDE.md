# MDE GCC High Onboarding - Deployment Guide

## Overview
Automated onboarding of Windows and Linux VMs in Azure Commercial to Microsoft Defender for Endpoint GCC High tenant.

**Target Environment:**
- **GCC High Tenant:** ugobami.onmicrosoft.us
- **Commercial Subscription:** d5de391c-9572-4dab-8610-32a41b3a860c
- **Resource Group:** Knightsmgmt01_group
- **Managed Identity:** bc4eff3e-ddf0-4a40-9bbf-311bce412071

---

## Prerequisites

### 1. Azure RBAC Permissions (Managed Identity)
Ensure the Automation Account's managed identity has:
- ✅ `Virtual Machine Contributor` on resource group
- ✅ `Storage Blob Data Reader` on storage account (for onboarding scripts)
- ✅ `Storage Blob Data Contributor` on storage account (for logs)

### 2. Onboarding Artifacts Required

#### Windows
- **File:** `WindowsDefenderATPLocalOnboardingScript.cmd`
- **Current Location:** https://teststrgaccount.blob.core.windows.net/mde/WindowsDefenderATPLocalOnboardingScript.cmd
- **Source:** Downloaded from https://security.microsoft.us (GCC High Defender portal)
- **Status:** ✅ Provided

#### Linux
- **File:** `mdatp_onboard.json`
- **Expected Location:** https://teststrgaccount.blob.core.windows.net/mde/mdatp_onboard.json
- **Source:** Downloaded from https://security.microsoft.us (GCC High Defender portal)
- **Status:** ⚠️ **MISSING - YOU MUST UPLOAD THIS**

**To generate Linux onboarding package:**
1. Go to https://security.microsoft.us
2. Navigate to: Settings → Endpoints → Onboarding
3. Select OS: **Linux Server**
4. Download the onboarding package (contains `mdatp_onboard.json`)
5. Upload to: `https://teststrgaccount.blob.core.windows.net/mde/mdatp_onboard.json`

### 3. Network Connectivity
Verify VMs can reach GCC High MDE endpoints:
- `*.securitycenter.microsoft.us`
- `*.blob.core.windows.net` (for downloading scripts)
- `packages.microsoft.com` (for Linux package installation)

---

## Deployment Steps

### Step 1: Upload Runbooks to Automation Account

Run these commands in Azure Cloud Shell or authenticated PowerShell session:

```powershell
# Variables
$subscriptionId = "d5de391c-9572-4dab-8610-32a41b3a860c"
$resourceGroup = "Knightsmgmt01_group"
$automationAccountName = "<YOUR_AUTOMATION_ACCOUNT_NAME>"  # REPLACE THIS

# Connect and set context
Connect-AzAccount
Set-AzContext -SubscriptionId $subscriptionId

# Import Windows onboarding runbook
Import-AzAutomationRunbook `
    -ResourceGroupName $resourceGroup `
    -AutomationAccountName $automationAccountName `
    -Path ".\Onboard-MDE-Windows-GCCH.ps1" `
    -Type PowerShell `
    -Name "Onboard-MDE-Windows-GCCH" `
    -Force

Publish-AzAutomationRunbook `
    -ResourceGroupName $resourceGroup `
    -AutomationAccountName $automationAccountName `
    -Name "Onboard-MDE-Windows-GCCH"

# Import Linux onboarding runbook
Import-AzAutomationRunbook `
    -ResourceGroupName $resourceGroup `
    -AutomationAccountName $automationAccountName `
    -Path ".\Onboard-MDE-Linux-GCCH.ps1" `
    -Type PowerShell `
    -Name "Onboard-MDE-Linux-GCCH" `
    -Force

Publish-AzAutomationRunbook `
    -ResourceGroupName $resourceGroup `
    -AutomationAccountName $automationAccountName `
    -Name "Onboard-MDE-Linux-GCCH"

Write-Host "✓ Runbooks imported and published successfully" -ForegroundColor Green
```

### Step 2: Execute Windows Onboarding

```powershell
# Start Windows onboarding runbook
$jobWindows = Start-AzAutomationRunbook `
    -ResourceGroupName $resourceGroup `
    -AutomationAccountName $automationAccountName `
    -Name "Onboard-MDE-Windows-GCCH" `
    -Parameters @{
        SubscriptionId = "d5de391c-9572-4dab-8610-32a41b3a860c"
        ResourceGroupName = "Knightsmgmt01_group"
        OnboardingScriptUrl = "https://teststrgaccount.blob.core.windows.net/mde/WindowsDefenderATPLocalOnboardingScript.cmd"
        StorageAccountName = "teststrgaccount"
        StorageContainerName = "mde-logs"
    }

Write-Host "Windows onboarding job started: $($jobWindows.JobId)" -ForegroundColor Cyan
Write-Host "Monitor at: https://portal.azure.com/#@ugobami.onmicrosoft.us/resource/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Automation/automationAccounts/$automationAccountName/jobs/$($jobWindows.JobId)/overview"
```

### Step 3: Execute Linux Onboarding (After uploading mdatp_onboard.json)

```powershell
# Start Linux onboarding runbook
$jobLinux = Start-AzAutomationRunbook `
    -ResourceGroupName $resourceGroup `
    -AutomationAccountName $automationAccountName `
    -Name "Onboard-MDE-Linux-GCCH" `
    -Parameters @{
        SubscriptionId = "d5de391c-9572-4dab-8610-32a41b3a860c"
        ResourceGroupName = "Knightsmgmt01_group"
        OnboardingJsonUrl = "https://teststrgaccount.blob.core.windows.net/mde/mdatp_onboard.json"
        StorageAccountName = "teststrgaccount"
        StorageContainerName = "mde-logs"
    }

Write-Host "Linux onboarding job started: $($jobLinux.JobId)" -ForegroundColor Cyan
```

### Step 4: Monitor Job Progress

```powershell
# Monitor Windows job
Get-AzAutomationJob -Id $jobWindows.JobId -ResourceGroupName $resourceGroup -AutomationAccountName $automationAccountName

# Get output stream
Get-AzAutomationJobOutput `
    -Id $jobWindows.JobId `
    -ResourceGroupName $resourceGroup `
    -AutomationAccountName $automationAccountName `
    -Stream Output | Get-AzAutomationJobOutputRecord | Select-Object -ExpandProperty Value

# Similarly for Linux
Get-AzAutomationJob -Id $jobLinux.JobId -ResourceGroupName $resourceGroup -AutomationAccountName $automationAccountName
```

---

## Validation

### 1. Check Onboarding Status in GCC High Portal
1. Go to https://security.microsoft.us
2. Navigate to: Assets → Devices
3. Verify VMs appear in device inventory (may take 5-15 minutes)

### 2. Check VM-Level Status

**Windows:**
```powershell
# Connect to VM and check SENSE service
sc.exe query sense

# Expected output: SERVICE_NAME: sense, STATE: 4 RUNNING
```

**Linux:**
```bash
# SSH to VM and check mdatp health
sudo mdatp health

# Expected output: healthy: true
sudo mdatp health --field org_id
# Should return GCC High org ID
```

### 3. Review Deployment Logs
Logs are uploaded to: `https://teststrgaccount.blob.core.windows.net/mde-logs/`
- `mde-onboarding-windows-YYYYMMDD-HHMMSS.json`
- `mde-onboarding-linux-YYYYMMDD-HHMMSS.json`

---

## Troubleshooting

### Issue: "Failed to download onboarding script"
**Cause:** Blob URL requires authentication or is incorrect.

**Solution:**
1. Verify blob exists at URL
2. Ensure managed identity has `Storage Blob Data Reader` role
3. Alternatively, generate SAS token with read permissions and append to URL

### Issue: "SENSE service not running" (Windows)
**Cause:** May require reboot after installation.

**Solution:**
```powershell
# Reboot VM
Restart-AzVM -ResourceGroupName "Knightsmgmt01_group" -Name "<VM_NAME>"
```

### Issue: "Unsupported distribution" (Linux)
**Cause:** MDE doesn't support that Linux distro.

**Solution:** Check supported distros at https://learn.microsoft.com/defender-endpoint/mde-linux-prerequisites

### Issue: "Package repository not reachable" (Linux)
**Cause:** Outbound internet blocked or proxy required.

**Solution:** Configure proxy or open firewall for `packages.microsoft.com`

---

## Retry Failed VMs

To retry only failed VMs, modify the runbook parameters:

```powershell
# Get failed VMs from previous log
$logBlob = Get-AzStorageBlob -Container "mde-logs" -Blob "mde-onboarding-windows-*.json" | Sort-Object -Property LastModified -Descending | Select-Object -First 1
$logContent = $logBlob | Get-AzStorageBlobContent -Destination "$env:TEMP\latest-log.json" -Force
$failedVMs = (Get-Content "$env:TEMP\latest-log.json" | ConvertFrom-Json) | Where-Object { $_.Status -eq 'Failed' } | Select-Object -ExpandProperty VMName

# Re-run for specific VMs only (manual execution via Azure portal or modify runbook to accept VM filter)
Write-Host "Failed VMs to retry: $($failedVMs -join ', ')"
```

---

## Next Steps After Successful Onboarding

1. **Verify in GCC High portal** that all devices appear
2. **Run detection test** to confirm sensors are functional
3. **Configure baseline security policies** in Defender portal:
   - Attack Surface Reduction rules
   - Next-gen protection settings
   - Tamper protection
4. **Set up automated response** for critical alerts
5. **Enable EDR in block mode** for additional protection

---

## Support & References

- **GCC High Defender Portal:** https://security.microsoft.us
- **Microsoft Docs:** https://learn.microsoft.com/defender-endpoint/gov
- **Gov MDE Endpoints:** https://learn.microsoft.com/defender-endpoint/gov#required-connectivity-settings
