# MDE GCC High Onboarding - Quick Start

## ⚠️ CRITICAL: Before You Start

### 1. Upload Linux Onboarding Package
You provided the Windows script, but **Linux onboarding requires `mdatp_onboard.json`**:

1. Go to **https://security.microsoft.us** (GCC High Defender portal)
2. Sign in with `ugobami.onmicrosoft.us` credentials
3. Navigate to: **Settings** → **Endpoints** → **Onboarding**
4. Select OS: **Linux Server**
5. Download the onboarding package
6. Upload `mdatp_onboard.json` to: **https://teststrgaccount.blob.core.windows.net/mde/mdatp_onboard.json**

### 2. Verify Blob Access
Ensure your onboarding scripts are accessible:
- Option A: Set container to **public read** access
- Option B: Generate **SAS token** with read permissions and append to URLs in runbooks

---

## 🚀 Deployment in 3 Commands

### Step 1: Open PowerShell with Azure Module
```powershell
# If not installed, run:
Install-Module -Name Az -AllowClobber -Scope CurrentUser -Force
```

### Step 2: Deploy Runbooks
```powershell
# Navigate to the folder containing the scripts
cd C:\path\to\mde-onboarding

# Run deployment (REPLACE <AUTOMATION_ACCOUNT_NAME> with your actual name)
.\Deploy-MDEOnboarding.ps1 -AutomationAccountName "<AUTOMATION_ACCOUNT_NAME>"
```

### Step 3: Start Onboarding
```powershell
# Start both Windows and Linux onboarding
.\Deploy-MDEOnboarding.ps1 -AutomationAccountName "<AUTOMATION_ACCOUNT_NAME>" -ExecuteImmediately
```

---

## 📋 What You Need to Provide

| Item | Value | Status |
|------|-------|--------|
| **Automation Account Name** | ??? | ⚠️ PROVIDE THIS |
| **Windows Script URL** | https://teststrgaccount.blob.core.windows.net/mde/WindowsDefenderATPLocalOnboardingScript.cmd | ✅ Provided |
| **Linux JSON URL** | https://teststrgaccount.blob.core.windows.net/mde/mdatp_onboard.json | ⚠️ UPLOAD REQUIRED |

---

## 🔍 Monitor Progress

### View Jobs in Azure Portal
```
https://portal.azure.com/#@ugobami.onmicrosoft.us/resource/subscriptions/d5de391c-9572-4dab-8610-32a41b3a860c/resourceGroups/Knightsmgmt01_group/providers/Microsoft.Automation/automationAccounts/<AUTOMATION_ACCOUNT_NAME>/jobs
```

### Check GCC High Defender Portal
```
https://security.microsoft.us → Assets → Devices
```
Devices should appear within 5-15 minutes after successful onboarding.

### View Logs
```
https://teststrgaccount.blob.core.windows.net/mde-logs/
```
JSON logs with detailed results for each VM.

---

## 🆘 If Something Fails

### Windows: "Failed to download onboarding script"
```powershell
# Test blob access
Invoke-WebRequest -Uri "https://teststrgaccount.blob.core.windows.net/mde/WindowsDefenderATPLocalOnboardingScript.cmd" -Method Head

# If fails, check blob permissions or add SAS token
```

### Linux: "Unsupported distribution"
Check supported distros: Ubuntu 16.04+, RHEL 7+, CentOS 7+, Debian 9+, SUSE 12+

### VM: "SENSE service not running"
May require reboot:
```powershell
Restart-AzVM -ResourceGroupName "Knightsmgmt01_group" -Name "<VM_NAME>"
```

---

## ✅ Success Validation

1. **Check Automation Job Output** → Should show "✓ SUCCESS" for each VM
2. **Check GCC High Portal** → Devices appear in inventory
3. **Check VM directly**:
   - Windows: `sc query sense` (should show RUNNING)
   - Linux: `sudo mdatp health` (should show healthy: true)

---

## 📞 Need Help?

All files created:
- `Onboard-MDE-Windows-GCCH.ps1` - Windows onboarding runbook
- `Onboard-MDE-Linux-GCCH.ps1` - Linux onboarding runbook
- `Deploy-MDEOnboarding.ps1` - Deployment automation script
- `DEPLOYMENT-GUIDE.md` - Complete technical documentation
- `QUICKSTART.md` - This file

**Ready to proceed when you provide your Automation Account name!**
