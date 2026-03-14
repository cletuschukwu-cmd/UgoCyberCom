<#
.SYNOPSIS
    Portable Azure Automation runbook to offboard Linux VMs from commercial MDE
    and onboard to GCC High MDE across all subscriptions.

.DESCRIPTION
    Repeatable, tenant-portable solution that:
    1. Authenticates via Automation Account Managed Identity
    2. Searches ALL subscriptions (or filtered list) for running Linux VMs
    3. For each VM:
       a. Detects the Linux OS distribution and MDE service state
       b. If MDE.Linux VM extension is installed, removes it; otherwise skips
       c. If mdatp (SENSE) service is actively running, runs the offboarding script; otherwise skips
       d. Runs the onboarding script to onboard to target (GCC High) tenant
       e. Reboots the VM and verifies health and org ID
    4. Produces a summary report

.PARAMETER OffboardingScriptBase64
    Base64-encoded content of the MDE offboarding Python script. Optional when
    the Automation variable (default: MDE-Linux-Offboard-B64) is configured.

.PARAMETER OnboardingScriptBase64
    Base64-encoded content of the MDE onboarding Python script. Optional when
    the Automation variable (default: MDE-Linux-Onboard-B64) is configured.

.PARAMETER OffboardingVariableName
    Automation variable name to use when OffboardingScriptBase64 is not
    provided. Default: MDE-Linux-Offboard-B64

.PARAMETER OnboardingVariableName
    Automation variable name to use when OnboardingScriptBase64 is not
    provided. Default: MDE-Linux-Onboard-B64

.PARAMETER SubscriptionFilter
    Optional. Array of subscription IDs to limit discovery.
    If omitted, ALL enabled subscriptions are searched.

.PARAMETER TagFilter
    Optional. Hashtable of tag key/value pairs to filter VMs.
    Example: @{Environment='Production'; Team='Security'}

.PARAMETER ExcludeVMs
    Optional. Array of VM names to skip.

.PARAMETER SkipReboot
    If set, skip VM reboot after onboarding.

.PARAMETER OffboardWaitSeconds
    Seconds to wait after offboarding before onboarding. Default: 30

.PARAMETER TenantId
    Optional. Azure AD Tenant ID to target. When omitted the Managed Identity's
    home tenant is used automatically. Supply this only when the Automation
    Account needs to explicitly target a specific tenant (e.g. a commercial
    Automation Account running against a GCC High tenant for discovery).

.PARAMETER DryRun
    If set, discovers VMs and evaluates MDE/SENSE state but makes NO changes:
    no extension removal, no offboarding, no onboarding, and no VM reboots.
    Use to validate scope and confirm target count before a production run.

.EXAMPLE
    # Run across all subscriptions
    .\Offboard-Onboard-MDE-Linux.ps1 `
        -OffboardingScriptBase64 (Get-Content .\linux_offboard_base64.txt -Raw) `
        -OnboardingScriptBase64  (Get-Content .\linux_onboard_base64.txt -Raw)

.EXAMPLE
    # Limit to specific subscriptions with tag filter
    .\Offboard-Onboard-MDE-Linux.ps1 `
        -OffboardingScriptBase64 $offB64 `
        -OnboardingScriptBase64  $onB64 `
        -SubscriptionFilter @("aaaa-bbbb-cccc", "dddd-eeee-ffff") `
        -TagFilter @{Environment='Production'}
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$OffboardingScriptBase64,

    [Parameter(Mandatory = $false)]
    [string]$OnboardingScriptBase64,

    [string]$OffboardingVariableName = 'MDE-Linux-Offboard-B64',

    [string]$OnboardingVariableName = 'MDE-Linux-Onboard-B64',

    [Parameter(Mandatory = $false)]
    [string[]]$SubscriptionFilter,

    [Parameter(Mandatory = $false)]
    [hashtable]$TagFilter,

    [Parameter(Mandatory = $false)]
    [string[]]$ExcludeVMs,

    [switch]$SkipReboot,

    [int]$OffboardWaitSeconds = 30,

    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# ===================================================================
# HELPERS
# ===================================================================
function Write-Step {
    param([string]$VM, [string]$Step, [string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Output "[$ts] [$VM] [$Step] $Message"
}

function Invoke-LinuxCommand {
    param(
        [string]$ResourceGroupName,
        [string]$VMName,
        [string]$Script
    )

    $maxAttempts  = 5
    $retryDelay   = 15
    $tempFile     = [IO.Path]::GetTempFileName() + '.sh'
    $Script       = $Script -replace "`r`n", "`n"

    [IO.File]::WriteAllText($tempFile, $Script, [System.Text.UTF8Encoding]::new($false))

    try {
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try {
                return Invoke-AzVMRunCommand `
                    -ResourceGroupName $ResourceGroupName `
                    -VMName            $VMName `
                    -CommandId         'RunShellScript' `
                    -ScriptPath        $tempFile
            }
            catch {
                $message = $_.Exception.Message
                $isRunCommandBusy = $message -match 'Run command extension execution is in progress' -or
                    ($message -match 'StatusCode: 409')

                if ($isRunCommandBusy -and $attempt -lt $maxAttempts) {
                    Write-Output "RunCommand busy on $VMName (attempt $attempt/$maxAttempts). Waiting $retryDelay seconds..."
                    Start-Sleep -Seconds $retryDelay
                }
                else {
                    throw
                }
            }
        }
    }
    finally {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-Base64Payload {
    param(
        [string]$InlineValue,
        [string]$VariableName,
        [string]$Label,
        [string]$ParameterName
    )

    if ($InlineValue -and $InlineValue.Trim().Length -gt 0) {
        return $InlineValue
    }

    if ($VariableName -and (Get-Command -Name Get-AutomationVariable -ErrorAction SilentlyContinue)) {
        Write-Output "Loading $Label content from Automation variable '$VariableName'..."
        $value = Get-AutomationVariable -Name $VariableName -ErrorAction Stop
        if (-not $value) {
            throw "Automation variable '$VariableName' for $Label is empty."
        }
        return $value
    }

    throw "No $Label content provided. Supply -$ParameterName or create Automation variable '$VariableName'."
}

# Payloads are loaded on first use so that:
#   - A clean VM (no MDE) never needs the offboard payload
#   - DryRun never loads either payload
$script:_OffboardB64 = $null
$script:_OnboardB64  = $null

function Get-OffboardPayload {
    if ($null -eq $script:_OffboardB64) {
        $raw = Get-Base64Payload `
            -InlineValue   $OffboardingScriptBase64 `
            -VariableName  $OffboardingVariableName `
            -Label         'Offboarding' `
            -ParameterName 'OffboardingScriptBase64'
        # Strip all whitespace/CRLF so the payload is a clean single-line Base64 string
        # safe for direct embedding into a bash heredoc without breaking base64 -d
        $script:_OffboardB64 = ($raw -replace '[\r\n\s]', '')
    }
    return $script:_OffboardB64
}

function Get-OnboardPayload {
    if ($null -eq $script:_OnboardB64) {
        $raw = Get-Base64Payload `
            -InlineValue   $OnboardingScriptBase64 `
            -VariableName  $OnboardingVariableName `
            -Label         'Onboarding' `
            -ParameterName 'OnboardingScriptBase64'
        # Strip all whitespace/CRLF so the payload is a clean single-line Base64 string
        $script:_OnboardB64 = ($raw -replace '[\r\n\s]', '')
    }
    return $script:_OnboardB64
}

# ===================================================================
# STEP 1: AUTHENTICATE via Managed Identity
# ===================================================================
Write-Output "===== MDE Linux Offboard & Onboard Runbook ====="
Write-Output "Connecting to Azure using Managed Identity..."
try {
    $connectParams = @{ Identity = $true }
    if ($TenantId) { $connectParams['TenantId'] = $TenantId }
    Connect-AzAccount @connectParams | Out-Null
    Write-Output "Authenticated successfully via Managed Identity."
}
catch {
    Write-Error "Failed to authenticate with Managed Identity: $_"
    throw
}

# ===================================================================
# STEP 2: DISCOVER Linux VMs across all subscriptions
# ===================================================================
Write-Output "`n$('=' * 70)"
Write-Output "DISCOVERY: Searching for Linux VMs..."
Write-Output ('=' * 70)

if ($SubscriptionFilter -and $SubscriptionFilter.Count -gt 0) {
    $subscriptions = $SubscriptionFilter | ForEach-Object {
        Get-AzSubscription -SubscriptionId $_ -ErrorAction SilentlyContinue
    } | Where-Object { $_.State -eq 'Enabled' }
    Write-Output "Scope: $($subscriptions.Count) specified subscription(s)"
}
else {
    $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' }
    Write-Output "Scope: ALL $($subscriptions.Count) enabled subscription(s)"
}

$discoveredVMs = @()

foreach ($sub in $subscriptions) {
    Write-Output "`n--- Subscription: $($sub.Name) ($($sub.Id)) ---"
    try {
        $null = Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop
    } catch {
        Write-Output "  [AUTH-FAIL] Cannot switch to subscription '$($sub.Name)' ($($sub.Id)): $($_.Exception.Message). Skipping — check Managed Identity RBAC."
        continue
    }

    $vms = Get-AzVM -Status -ErrorAction SilentlyContinue | Where-Object {
        $_.StorageProfile.OSDisk.OSType -eq 'Linux' -and
        $_.PowerState -eq 'VM running'
    }

    if (-not $vms) {
        Write-Output "  No running Linux VMs found."
        continue
    }

    foreach ($v in $vms) {
        # Tag filter
        if ($TagFilter -and $TagFilter.Count -gt 0) {
            $matchesTags = $true
            foreach ($key in $TagFilter.Keys) {
                if ($v.Tags[$key] -ne $TagFilter[$key]) {
                    $matchesTags = $false
                    break
                }
            }
            if (-not $matchesTags) {
                Write-Output "  Skipping $($v.Name) - tag filter mismatch"
                continue
            }
        }

        # Exclusion list
        if ($ExcludeVMs -and $ExcludeVMs -contains $v.Name) {
            Write-Output "  Skipping $($v.Name) - excluded"
            continue
        }

        Write-Output "  Found: $($v.Name) (RG: $($v.ResourceGroupName))"
        $discoveredVMs += @{
            VMName            = $v.Name
            ResourceGroupName = $v.ResourceGroupName
            SubscriptionId    = $sub.Id
            SubscriptionName  = $sub.Name
        }
    }
}

if ($discoveredVMs.Count -eq 0) {
    Write-Output "`nNo Linux VMs found. Nothing to do."
    return
}

Write-Output "`n$('=' * 70)"
Write-Output "Discovered $($discoveredVMs.Count) Linux VM(s) to process."
if ($DryRun) { Write-Output "*** DRY RUN MODE - No changes will be made ***" }
Write-Output ('=' * 70)

# ===================================================================
# STEP 3: PROCESS each VM
# ===================================================================
$results = @()
$originalContext = Get-AzContext

foreach ($vm in $discoveredVMs) {
    $vmName  = $vm.VMName
    $rgName  = $vm.ResourceGroupName
    $subId   = $vm.SubscriptionId
    $subName = $vm.SubscriptionName

    # Switch subscription if needed
    $currentCtx = Get-AzContext
    if ($currentCtx.Subscription.Id -ne $subId) {
        Write-Output "`nSwitching to subscription: $subName ($subId)"
        try {
            $null = Set-AzContext -SubscriptionId $subId -ErrorAction Stop
        } catch {
            $authMsg = "[AUTH-FAIL] Cannot switch to subscription '$subName' ($subId): $($_.Exception.Message). Skipping VM: $vmName"
            Write-Output $authMsg
            $vmResult.Status  = 'Failed'
            $vmResult.Message = $authMsg
            $results += $vmResult
            continue
        }
    }

    Write-Output "`n$('=' * 70)"
    Write-Output "VM: $vmName | RG: $rgName | Sub: $subName"
    Write-Output ('=' * 70)

    $vmResult = [PSCustomObject]@{
        Timestamp        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        VMName           = $vmName
        ResourceGroup    = $rgName
        Subscription     = $subName
        SubscriptionId   = $subId
        Distro           = 'Unknown'
        ExtensionRemoved = $false
        MdatpWasRunning  = $false
        OffboardStatus   = 'Skipped'
        OnboardStatus    = 'Skipped'
        NewOrgId         = ''
        Status           = 'InProgress'
        Message          = ''
    }

    try {
        # -----------------------------------------------------------
        # PHASE 1: Detect OS distro + check mdatp/SENSE status
        # -----------------------------------------------------------
        Write-Step $vmName "DETECT" "Checking OS distribution and MDE status..."

        $detectScript = @'
#!/bin/bash
echo "=== OS and MDE Detection ==="

# Detect distro
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "distro=$ID"
    echo "distro_version=$VERSION_ID"
    echo "distro_name=$PRETTY_NAME"
else
    echo "distro=unknown"
fi

# Check mdatp / SENSE
if command -v mdatp &>/dev/null; then
    echo "mdatp_installed=true"
    echo "mdatp_service=$(systemctl is-active mdatp 2>/dev/null)"
    ORG_ID=$(mdatp health --field org_id 2>/dev/null | tr -d '"')
    echo "org_id=$ORG_ID"
    echo "healthy=$(mdatp health --field healthy 2>/dev/null)"
    echo "licensed=$(mdatp health --field licensed 2>/dev/null)"
    ONBOARDED=$(mdatp health --field onboarded 2>/dev/null | tr -d '"')
    if echo "$ONBOARDED" | grep -qi 'true'; then
        echo "onboarded=true"
    else
        echo "onboarded=false"
    fi
else
    echo "mdatp_installed=false"
    echo "mdatp_service=not-installed"
    echo "onboarded=false"
fi

# Check python availability
echo "python3=$(which python3 2>/dev/null || echo 'not found')"
echo "python=$(which python 2>/dev/null || echo 'not found')"
'@

        $detectResult = Invoke-LinuxCommand -ResourceGroupName $rgName -VMName $vmName -Script $detectScript
        $detectOutput = $detectResult.Value[0].Message
        Write-Step $vmName "DETECT" $detectOutput

        # Parse distro
        if ($detectOutput -match 'distro_name=(.+)') { $vmResult.Distro = $Matches[1].Trim() }
        elseif ($detectOutput -match 'distro=(\S+)') { $vmResult.Distro = $Matches[1].Trim() }

        # Parse mdatp status
        $mdatpRunning             = $detectOutput -match 'mdatp_service=active'
        $mdatpOnboarded           = $detectOutput -match 'onboarded=true'
        $vmResult.MdatpWasRunning = $mdatpRunning

        # -----------------------------------------------------------
        # PHASE 2: Check and remove MDE.Linux VM extension
        # -----------------------------------------------------------
        Write-Step $vmName "EXTENSION" "Checking for MDE.Linux extension..."

        $ext = Get-AzVMExtension -ResourceGroupName $rgName -VMName $vmName -Name 'MDE.Linux' -ErrorAction SilentlyContinue
        if ($ext) {
            if ($DryRun) {
                Write-Step $vmName "EXTENSION" "[DryRun] Would remove MDE.Linux extension (Status: $($ext.ProvisioningState))."
            }
            else {
                Write-Step $vmName "EXTENSION" "MDE.Linux extension found (Status: $($ext.ProvisioningState)). Removing..."
                Remove-AzVMExtension -ResourceGroupName $rgName -VMName $vmName -Name 'MDE.Linux' -Force
                $vmResult.ExtensionRemoved = $true
                Write-Step $vmName "EXTENSION" "MDE.Linux extension removed."
            }
        }
        else {
            Write-Step $vmName "EXTENSION" "MDE.Linux extension not present."
        }

        # -----------------------------------------------------------
        # PHASE 3: Offboard (only if mdatp service is actively running)
        # -----------------------------------------------------------
        if ($mdatpRunning -and $mdatpOnboarded) {
            Write-Step $vmName "OFFBOARD" "mdatp service is running and onboarded. Running offboarding script..."

            if ($DryRun) {
                Write-Step $vmName "OFFBOARD" "[DryRun] Skipping offboard execution."
                $vmResult.OffboardStatus = 'DryRun'
            }
            else {
                # Step 1: Write the Base64 payload to the VM using RunCommand -Parameter
                # This avoids embedding large strings in the script body (which breaks base64 -d)
                $writeOffboardScript = @'
#!/bin/bash
printf '%s' "$PAYLOAD" > /tmp/mde_offboard_b64.txt
echo "write_exit=$?"
'@
                $null = Invoke-AzVMRunCommand `
                    -ResourceGroupName $rgName `
                    -VMName            $vmName `
                    -CommandId         'RunShellScript' `
                    -ScriptString      $writeOffboardScript `
                    -Parameter         @([pscustomobject]@{ name = 'PAYLOAD'; value = (Get-OffboardPayload) })

                # Step 2: Decode and run the offboarding script
                $offboardShell = @'
#!/bin/bash
echo "=== Offboarding from current MDE tenant ==="
if [ ! -f /tmp/mde_offboard_b64.txt ]; then echo "ERROR: payload file not found"; exit 1; fi
base64 -d /tmp/mde_offboard_b64.txt > /tmp/mde_offboard.py
if [ $? -ne 0 ]; then echo "ERROR: base64 decode failed"; exit 1; fi
chmod +x /tmp/mde_offboard.py
python3 /tmp/mde_offboard.py 2>&1
OFFBOARD_EXIT=$?
echo "offboard_exit_code=$OFFBOARD_EXIT"
sleep 5
if command -v mdatp &>/dev/null; then
    echo "post_offboard_org_id=$(mdatp health --field org_id 2>/dev/null | tr -d '"')"
    echo "post_offboard_service=$(systemctl is-active mdatp 2>/dev/null)"
fi
rm -f /etc/opt/microsoft/mdatp/mdatp_onboard.json
rm -f /tmp/mde_offboard.py /tmp/mde_offboard_b64.txt
echo "Offboarding complete."
'@

                $offResult = Invoke-LinuxCommand -ResourceGroupName $rgName -VMName $vmName -Script $offboardShell
                $offOutput = $offResult.Value[0].Message
                Write-Step $vmName "OFFBOARD" $offOutput

                if ($offResult.Value[1].Message) {
                    Write-Step $vmName "OFFBOARD" "STDERR: $($offResult.Value[1].Message)"
                }

                $vmResult.OffboardStatus = if ($offOutput -match 'offboard_exit_code=0') { 'Success' } else { 'Failed' }

                # Wait for offboarding to settle
                Write-Step $vmName "WAIT" "Waiting $OffboardWaitSeconds seconds..."
                Start-Sleep -Seconds $OffboardWaitSeconds
            }
        }
        else {
            if (-not $mdatpRunning) {
                Write-Step $vmName "OFFBOARD" "mdatp service is not running. Skipping offboarding."
            } else {
                Write-Step $vmName "OFFBOARD" "mdatp is installed but NOT onboarded to any tenant (unlicensed/orphaned). Skipping offboarding."
            }
            $vmResult.OffboardStatus = 'NotNeeded'
        }

        # -----------------------------------------------------------
        # PHASE 4: Onboard to target (GCCH) tenant
        # -----------------------------------------------------------
        Write-Step $vmName "ONBOARD" "Running onboarding script..."

        if ($DryRun) {
            Write-Step $vmName "ONBOARD" "[DryRun] Skipping onboard execution."
            $vmResult.OnboardStatus = 'DryRun'
        }
        else {
            # Step 1: Write the onboard Base64 payload to the VM
            $writeOnboardScript = @'
#!/bin/bash
printf '%s' "$PAYLOAD" > /tmp/mde_onboard_b64.txt
echo "write_exit=$?"
'@
            $null = Invoke-AzVMRunCommand `
                -ResourceGroupName $rgName `
                -VMName            $vmName `
                -CommandId         'RunShellScript' `
                -ScriptString      $writeOnboardScript `
                -Parameter         @([pscustomobject]@{ name = 'PAYLOAD'; value = (Get-OnboardPayload) })

            # Step 2: Decode and run the onboarding script
            $onboardShell = @'
#!/bin/bash
echo "=== Onboarding to target MDE tenant ==="
if [ ! -f /tmp/mde_onboard_b64.txt ]; then echo "ERROR: payload file not found"; exit 1; fi
base64 -d /tmp/mde_onboard_b64.txt > /tmp/mde_onboard.py
if [ $? -ne 0 ]; then echo "ERROR: base64 decode failed"; exit 1; fi
chmod +x /tmp/mde_onboard.py
python3 /tmp/mde_onboard.py 2>&1
ONBOARD_EXIT=$?
echo "onboard_exit_code=$ONBOARD_EXIT"
if [ -f /etc/opt/microsoft/mdatp/mdatp_onboard.json ]; then
    echo "onboard_json=present"
else
    echo "onboard_json=missing"
    echo "ERROR: Onboard json was not created!"
fi
systemctl restart mdatp 2>/dev/null
sleep 10
if command -v mdatp &>/dev/null; then
    echo "=== Post-Onboard Verification ==="
    NEW_ORG=$(mdatp health --field org_id 2>/dev/null | tr -d '"')
    echo "new_org_id=$NEW_ORG"
    echo "service_status=$(systemctl is-active mdatp 2>/dev/null)"
    echo "healthy=$(mdatp health --field healthy 2>/dev/null)"
    echo "licensed=$(mdatp health --field licensed 2>/dev/null)"
fi
rm -f /tmp/mde_onboard.py /tmp/mde_onboard_b64.txt
echo "Onboarding complete."
'@

            $onResult = Invoke-LinuxCommand -ResourceGroupName $rgName -VMName $vmName -Script $onboardShell
            $onOutput = $onResult.Value[0].Message
            Write-Step $vmName "ONBOARD" $onOutput

            if ($onResult.Value[1].Message) {
                Write-Step $vmName "ONBOARD" "STDERR: $($onResult.Value[1].Message)"
            }

            # Parse results
            if ($onOutput -match 'new_org_id=(\S+)') { $vmResult.NewOrgId = $Matches[1] }
            $vmResult.OnboardStatus = if ($onOutput -match 'onboard_exit_code=0' -and $onOutput -match 'service_status=active') { 'Success' }
                                      elseif ($onOutput -match 'onboard_exit_code=0') { 'PartialSuccess' }
                                      else { 'Failed' }
        }

        # -----------------------------------------------------------
        # PHASE 5: Reboot (optional)
        # -----------------------------------------------------------
        if (-not $SkipReboot) {
            if ($DryRun) {
                Write-Step $vmName "REBOOT" "[DryRun] Would reboot VM."
            }
            else {
                Write-Step $vmName "REBOOT" "Rebooting VM..."
                Restart-AzVM -ResourceGroupName $rgName -Name $vmName
                Write-Step $vmName "REBOOT" "Reboot initiated."

                $maxWait = 300; $elapsed = 0
                do {
                    Start-Sleep -Seconds 15; $elapsed += 15
                    $vmStatus   = Get-AzVM -ResourceGroupName $rgName -Name $vmName -Status
                    $powerState = ($vmStatus.Statuses | Where-Object { $_.Code -like 'PowerState/*' }).DisplayStatus
                } while ($powerState -ne 'VM running' -and $elapsed -lt $maxWait)

                if ($powerState -eq 'VM running') {
                    Write-Step $vmName "REBOOT" "VM is running. Waiting 30s for services..."
                    Start-Sleep -Seconds 30

                    $finalCheck = @'
#!/bin/bash
echo "=== Final Post-Reboot Verification ==="
if command -v mdatp &>/dev/null; then
    echo "service_status=$(systemctl is-active mdatp 2>/dev/null)"
    echo "org_id=$(mdatp health --field org_id 2>/dev/null | tr -d '"')"
    echo "healthy=$(mdatp health --field healthy 2>/dev/null)"
    echo "licensed=$(mdatp health --field licensed 2>/dev/null)"
    echo "real_time_protection=$(mdatp health --field real_time_protection_enabled 2>/dev/null)"
else
    echo "WARNING: mdatp not found after reboot"
fi
'@
                    $finalResult = Invoke-LinuxCommand -ResourceGroupName $rgName -VMName $vmName -Script $finalCheck
                    Write-Step $vmName "VERIFY" $finalResult.Value[0].Message
                }
                else {
                    Write-Step $vmName "REBOOT" "WARNING: VM did not come back within $maxWait seconds"
                }
            }
        }
        else {
            Write-Step $vmName "REBOOT" "Skipped (-SkipReboot)"
        }

        $vmResult.Status  = $vmResult.OnboardStatus
        $vmResult.Message = "Distro: $($vmResult.Distro) | Ext removed: $($vmResult.ExtensionRemoved) | Offboard: $($vmResult.OffboardStatus) | Onboard: $($vmResult.OnboardStatus)"
    }
    catch {
        $vmResult.Status  = 'Failed'
        $vmResult.Message = "Error: $($_.Exception.Message)"
        Write-Step $vmName "ERROR" $vmResult.Message
    }

    $results += $vmResult
    Write-Step $vmName "DONE" $vmResult.Message
}

# ===================================================================
# STEP 4: SUMMARY REPORT
# ===================================================================
Write-Output "`n$('=' * 70)"
Write-Output "SUMMARY REPORT"
Write-Output ('=' * 70)

$successCount = ($results | Where-Object { $_.Status -eq 'Success' }).Count
$partialCount = ($results | Where-Object { $_.Status -eq 'PartialSuccess' }).Count
$failedCount  = ($results | Where-Object { $_.Status -eq 'Failed' }).Count
$dryRunCount  = ($results | Where-Object { $_.Status -eq 'DryRun' }).Count

Write-Output "Total VMs processed : $($results.Count)"
Write-Output "Success             : $successCount"
Write-Output "Partial             : $partialCount"
Write-Output "Failed              : $failedCount"
if ($dryRunCount -gt 0) { Write-Output "DryRun (no changes) : $dryRunCount" }

Write-Output "`nDetailed Results:"
$results | Format-Table -AutoSize VMName, Subscription, Distro, ExtensionRemoved, OffboardStatus, OnboardStatus, NewOrgId, Status

# Restore original context
if ($originalContext) {
    $null = Set-AzContext -SubscriptionId $originalContext.Subscription.Id -ErrorAction SilentlyContinue
}

Write-Output "`n===== Runbook Complete ====="
