# First, check if there's stale onboarding from the old tenant and clean it
Write-Host "=== Pre-Onboarding Cleanup ==="
$senseStatus = Get-Service -Name SENSE -ErrorAction SilentlyContinue
Write-Host "SENSE Service Status: $($senseStatus.Status), StartType: $($senseStatus.StartType)"

# Check registry for old onboarding
$atpReg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status' -ErrorAction SilentlyContinue
Write-Host "Current OrgId: $($atpReg.OrgId)"
Write-Host "Current OnboardingState: $($atpReg.OnboardingState)"

# Check policy key
$policyReg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection' -ErrorAction SilentlyContinue
Write-Host "Policy OnboardingInfo exists: $($null -ne $policyReg.OnboardingInfo)"
if ($policyReg.OnboardingInfo) {
    $info = $policyReg.OnboardingInfo | ConvertFrom-Json
    $body = $info.body | ConvertFrom-Json
    Write-Host "Policy OrgId: $($body.orgId)"
    Write-Host "Policy GeoLocation: $($body.geoLocationUrl)"
    Write-Host "Policy Datacenter: $($body.datacenter)"
}
Write-Host ""
Write-Host "=== Current SENSE service details ==="
sc.exe query sense
sc.exe qc sense
