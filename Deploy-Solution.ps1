<#
.SYNOPSIS
    One-shot, fully automated deployment of the MDE Linux Offboard/Onboard solution.
    No human intervention required after the initial Azure login.

.DESCRIPTION
    This script:
      1. Connects to Azure (interactive login once — Managed Identity takes over after)
      2. Uploads and publishes the Offboard-Onboard-MDE-Linux runbook
      3. Stores offboard/onboard Base64 payloads as Automation Variables
      4. Assigns Virtual Machine Contributor + Reader to the Automation Account
         Managed Identity across EVERY enabled subscription in the tenant
      5. Triggers a DryRun job and waits for it to complete
      6. On DryRun success, triggers the live run and streams the output

.NOTES
    All configuration is hardcoded for the knightsautomation / daveanddaveus.net tenant.
    Run once from any machine with Az PowerShell module and Azure access.
    Required Az modules: Az.Accounts, Az.Automation, Az.Compute, Az.Resources
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ── Configuration (no changes needed) ───────────────────────────────────────
$AutomationSubscriptionId = 'd5de391c-9572-4dab-8610-32a41b3a860c'
$AutomationResourceGroup  = 'tier2Sentinel_RG'
$AutomationAccountName    = 'knightsautomation'
$RunbookName              = 'Offboard-Onboard-MDE-Linux'
$OffboardVarName          = 'MDE-Linux-Offboard-B64'
$OnboardVarName           = 'MDE-Linux-Onboard-B64'

$RunbookPath     = Join-Path $PSScriptRoot 'Offboard-Onboard-MDE-Linux.ps1'
$OffboardB64Path = Join-Path $PSScriptRoot 'linux_offboard_base64.txt'
$OnboardB64Path  = Join-Path $PSScriptRoot 'linux_onboard_base64.txt'
# ─────────────────────────────────────────────────────────────────────────────

function Write-Banner { param([string]$Text)
    Write-Host "`n$('═' * 70)" -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host "$('═' * 70)" -ForegroundColor Cyan
}
function Write-OK    { param([string]$Text) Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Warn  { param([string]$Text) Write-Host "  [WARN] $Text" -ForegroundColor Yellow }
function Write-Doing { param([string]$Text) Write-Host "  [...] $Text"  -ForegroundColor Gray }

# ── STEP 1: Authenticate ─────────────────────────────────────────────────────
Write-Banner "STEP 1 of 7 — Authenticate to Azure"
Write-Doing "Checking existing Azure context..."
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx) {
    Write-Doing "No existing session. Launching interactive login..."
    Connect-AzAccount -ErrorAction Stop | Out-Null
}
Set-AzContext -SubscriptionId $AutomationSubscriptionId -ErrorAction Stop | Out-Null
Write-OK "Authenticated. Context set to Automation subscription: $AutomationSubscriptionId"

# ── STEP 2: Validate local files ─────────────────────────────────────────────
Write-Banner "STEP 2 of 7 — Validate Local Files"
foreach ($f in @($RunbookPath, $OffboardB64Path, $OnboardB64Path)) {
    if (-not (Test-Path $f)) {
        throw "Required file not found: $f`nEnsure you are running from the repo root or that the file exists."
    }
    Write-OK "Found: $(Split-Path $f -Leaf)"
}

# ── STEP 3: Upload and publish runbook ───────────────────────────────────────
Write-Banner "STEP 3 of 7 — Upload & Publish Runbook"
Write-Doing "Importing runbook '$RunbookName' into '$AutomationAccountName'..."
Import-AzAutomationRunbook `
    -ResourceGroupName     $AutomationResourceGroup `
    -AutomationAccountName $AutomationAccountName `
    -Path                  $RunbookPath `
    -Type                  PowerShell `
    -Name                  $RunbookName `
    -Description           'Offboards Linux VMs from commercial MDE and re-onboards to GCC High MDE. Scans all subscriptions in the tenant automatically.' `
    -Force | Out-Null

Write-Doing "Publishing runbook..."
Publish-AzAutomationRunbook `
    -ResourceGroupName     $AutomationResourceGroup `
    -AutomationAccountName $AutomationAccountName `
    -Name                  $RunbookName | Out-Null

Write-OK "Runbook published: $RunbookName"

# ── STEP 4: Store Base64 payloads as Automation Variables ────────────────────
Write-Banner "STEP 4 of 7 — Store Payloads as Automation Variables"
$offboardB64 = (Get-Content $OffboardB64Path -Raw).Trim()
$onboardB64  = (Get-Content $OnboardB64Path  -Raw).Trim()

foreach ($var in @(
    @{ Name = $OffboardVarName; Value = $offboardB64; Label = 'Offboard' }
    @{ Name = $OnboardVarName;  Value = $onboardB64;  Label = 'Onboard'  }
)) {
    $sizeKB = [math]::Round($var.Value.Length / 1024, 1)
    Write-Doing "Storing '$($var.Name)' ($sizeKB KB)..."

    $existing = Get-AzAutomationVariable `
        -ResourceGroupName     $AutomationResourceGroup `
        -AutomationAccountName $AutomationAccountName `
        -Name                  $var.Name `
        -ErrorAction           SilentlyContinue

    if ($existing) {
        Set-AzAutomationVariable `
            -ResourceGroupName     $AutomationResourceGroup `
            -AutomationAccountName $AutomationAccountName `
            -Name                  $var.Name `
            -Value                 $var.Value `
            -Encrypted             $false | Out-Null
        Write-OK "Updated: $($var.Name)"
    } else {
        New-AzAutomationVariable `
            -ResourceGroupName     $AutomationResourceGroup `
            -AutomationAccountName $AutomationAccountName `
            -Name                  $var.Name `
            -Value                 $var.Value `
            -Encrypted             $false | Out-Null
        Write-OK "Created: $($var.Name)"
    }
}

# ── STEP 5: Assign RBAC to Managed Identity across all subscriptions ──────────
Write-Banner "STEP 5 of 7 — Assign RBAC Across All Subscriptions"

# Retrieve the MI Principal ID from the Automation Account itself
$aa = Get-AzAutomationAccount `
    -ResourceGroupName $AutomationResourceGroup `
    -Name              $AutomationAccountName `
    -ErrorAction Stop

$miPrincipalId = $aa.Identity.PrincipalId
if (-not $miPrincipalId) {
    throw @"
Automation Account '$AutomationAccountName' does not have a System-Assigned Managed Identity.
Enable it: Azure Portal → Automation Accounts → $AutomationAccountName → Identity → System assigned → On → Save.
Then re-run this script.
"@
}
Write-OK "Managed Identity Principal ID: $miPrincipalId"

# Discover all enabled subscriptions in the tenant
$subscriptions = Get-AzSubscription -ErrorAction Stop | Where-Object { $_.State -eq 'Enabled' }
Write-OK "Found $($subscriptions.Count) enabled subscription(s) in tenant."

foreach ($sub in $subscriptions) {
    $scope = "/subscriptions/$($sub.Id)"
    Write-Doing "Processing: $($sub.Name) ($($sub.Id))"

    # Virtual Machine Contributor — required for RunCommand, extension removal, restart
    $hasVMC = Get-AzRoleAssignment `
        -ObjectId           $miPrincipalId `
        -RoleDefinitionName 'Virtual Machine Contributor' `
        -Scope              $scope `
        -ErrorAction        SilentlyContinue
    if ($hasVMC) {
        Write-OK "  Virtual Machine Contributor — already assigned"
    } else {
        try {
            New-AzRoleAssignment `
                -ObjectId           $miPrincipalId `
                -RoleDefinitionName 'Virtual Machine Contributor' `
                -Scope              $scope | Out-Null
            Write-OK "  Virtual Machine Contributor — assigned"
        } catch {
            Write-Warn "  Could not assign Virtual Machine Contributor on '$($sub.Name)': $($_.Exception.Message)"
        }
    }

    # Reader — required for Get-AzSubscription context switching across subs
    $hasReader = Get-AzRoleAssignment `
        -ObjectId           $miPrincipalId `
        -RoleDefinitionName 'Reader' `
        -Scope              $scope `
        -ErrorAction        SilentlyContinue
    if ($hasReader) {
        Write-OK "  Reader — already assigned"
    } else {
        try {
            New-AzRoleAssignment `
                -ObjectId           $miPrincipalId `
                -RoleDefinitionName 'Reader' `
                -Scope              $scope | Out-Null
            Write-OK "  Reader — assigned"
        } catch {
            Write-Warn "  Could not assign Reader on '$($sub.Name)': $($_.Exception.Message)"
        }
    }
}

# Restore context to Automation Account subscription
Set-AzContext -SubscriptionId $AutomationSubscriptionId | Out-Null

# ── STEP 6: DryRun ───────────────────────────────────────────────────────────
Write-Banner "STEP 6 of 7 — DryRun (Discovery Only — No Changes)"
Write-Doing "Starting DryRun job..."
$dryRunJob = Start-AzAutomationRunbook `
    -ResourceGroupName     $AutomationResourceGroup `
    -AutomationAccountName $AutomationAccountName `
    -Name                  $RunbookName `
    -Parameters            @{ DryRun = $true } `
    -ErrorAction           Stop

Write-OK "DryRun Job ID: $($dryRunJob.JobId)"
Write-Doing "Waiting for DryRun to complete..."

$timeout = 1800; $elapsed = 0; $pollInterval = 30
do {
    Start-Sleep -Seconds $pollInterval
    $elapsed += $pollInterval
    $dryJob = Get-AzAutomationJob `
        -Id                    $dryRunJob.JobId `
        -ResourceGroupName     $AutomationResourceGroup `
        -AutomationAccountName $AutomationAccountName
    Write-Doing "  Job status: $($dryJob.Status) — $elapsed s elapsed"
} while ($dryJob.Status -notin @('Completed','Failed','Stopped','Suspended') -and $elapsed -lt $timeout)

Write-Host "`n--- DryRun Output ---" -ForegroundColor Cyan
Get-AzAutomationJobOutput `
    -Id                    $dryRunJob.JobId `
    -ResourceGroupName     $AutomationResourceGroup `
    -AutomationAccountName $AutomationAccountName `
    -Stream                Output |
    Get-AzAutomationJobOutputRecord |
    ForEach-Object { Write-Host $_.Value.value }

if ($dryJob.Status -ne 'Completed') {
    throw "DryRun job ended with status '$($dryJob.Status)'. Review the output above before proceeding. Aborting live run."
}
Write-OK "DryRun completed successfully. Proceeding to live run."

# ── STEP 7: Live Run ─────────────────────────────────────────────────────────
Write-Banner "STEP 7 of 7 — LIVE RUN"
Write-Doing "Starting live run across all subscriptions..."
$liveJob = Start-AzAutomationRunbook `
    -ResourceGroupName     $AutomationResourceGroup `
    -AutomationAccountName $AutomationAccountName `
    -Name                  $RunbookName `
    -ErrorAction           Stop

Write-OK "Live Job ID: $($liveJob.JobId)"
Write-Doing "Waiting for live run to complete (may take a long time depending on VM count)..."

$timeout = 7200; $elapsed = 0
do {
    Start-Sleep -Seconds $pollInterval
    $elapsed += $pollInterval
    $liveJobStatus = Get-AzAutomationJob `
        -Id                    $liveJob.JobId `
        -ResourceGroupName     $AutomationResourceGroup `
        -AutomationAccountName $AutomationAccountName
    Write-Doing "  Job status: $($liveJobStatus.Status) — $elapsed s elapsed"
} while ($liveJobStatus.Status -notin @('Completed','Failed','Stopped','Suspended') -and $elapsed -lt $timeout)

Write-Host "`n--- Live Run Output ---" -ForegroundColor Cyan
Get-AzAutomationJobOutput `
    -Id                    $liveJob.JobId `
    -ResourceGroupName     $AutomationResourceGroup `
    -AutomationAccountName $AutomationAccountName `
    -Stream                Output |
    Get-AzAutomationJobOutputRecord |
    ForEach-Object { Write-Host $_.Value.value }

# ── Final Summary ─────────────────────────────────────────────────────────────
Write-Banner "DEPLOYMENT COMPLETE"
$color = if ($liveJobStatus.Status -eq 'Completed') { 'Green' } else { 'Red' }
Write-Host "  Live Job Status : $($liveJobStatus.Status)" -ForegroundColor $color
Write-Host "  Live Job ID     : $($liveJob.JobId)"        -ForegroundColor Gray
Write-Host "`n  Verify devices at: https://security.microsoft.us → Assets → Devices" -ForegroundColor Cyan
Write-Host "  Allow 5-15 minutes for devices to appear in the portal.`n"
