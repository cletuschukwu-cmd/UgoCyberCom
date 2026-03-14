Write-Host "=== GCC High MDE Onboarding ==="
Write-Host ""

# Step 1: Set latency reg key
reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection" /v latency /t REG_SZ /f /d "Demo" 2>&1 | Out-Null
Write-Host "[1/6] Latency policy set"

# Step 2: Set WMI security
$sdbin = "01000480440000005400000000000000140000000200300002000000000014000FF0F120001010000000000051200000000001400E104120001010000000000050B0000000102000000000005200000002002000001020000000000052000000020020000"
reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\WMI\Security" /v "14f8138e-3b61-580b-544b-2609378ae460" /t REG_BINARY /d $sdbin /f 2>&1 | Out-Null
reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\WMI\Security" /v "cb2ff72d-d4e4-585d-33f9-f3a395c40be7" /t REG_BINARY /d $sdbin /f 2>&1 | Out-Null
Write-Host "[2/6] WMI security configured"

# Step 3: Disable enterprise auth proxy
reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v DisableEnterpriseAuthProxy /t REG_DWORD /f /d 1 2>&1 | Out-Null
Write-Host "[3/6] Enterprise auth proxy disabled"

# Step 4: Install ELAM certificate
try {
    Add-Type 'using System; using System.IO; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles; using System.ComponentModel; public static class Elam{ [DllImport("Kernel32", CharSet=CharSet.Auto, SetLastError=true)] public static extern bool InstallELAMCertificateInfo(SafeFileHandle handle); public static void InstallWdBoot(string path) { var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read); var handle = stream.SafeFileHandle; if (!InstallELAMCertificateInfo(handle)) { throw new Win32Exception(Marshal.GetLastWin32Error()); } } }'
    $driverPath = "$env:SystemRoot\System32\Drivers\WdBoot.sys"
    [Elam]::InstallWdBoot($driverPath)
    Write-Host "[4/6] ELAM certificate installed"
} catch {
    Write-Host "[4/6] ELAM certificate install skipped: $_"
}

# Step 5: Remove any old offboarding info, then set GCC High onboarding info
$offboardCheck = reg.exe query "HKLM\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection" /v "696C1FA1-4030-4FA4-8713-FAF9B2EA7C0A" /reg:64 2>&1
if ($LASTEXITCODE -eq 0) {
    reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection" /v "696C1FA1-4030-4FA4-8713-FAF9B2EA7C0A" /f 2>&1 | Out-Null
    Write-Host "[5a/6] Removed old offboarding info"
}

$onboardingJson = '{"body":"{\"previousOrgIds\":[],\"orgId\":\"792901cc-8460-4fbb-a191-07b76285fa96\",\"geoLocationUrl\":\"https://edr-usgt.usg.endpoint.security.microsoft.us/edr/\",\"datacenter\":\"UsGovTexas\",\"vortexGeoLocation\":\"FFL4\",\"vortexServerUrl\":\"https://us4-v20.events.endpoint.security.microsoft.us/OneCollector/1.0\",\"vortexTicketUrl\":\"https://events.data.microsoft.com\",\"partnerGeoLocation\":\"GW_FFL4\",\"version\":\"2.11\",\"packageGuid\":\"648805aa-4759-461e-880a-061bef7b7938\"}","sig":"e6PENxgZDTTtgpIsQnQSqyakd5IvmWk1Q5wMSYE9sxzJvTVSxUWThgN1wq28/6ZTFJuQ2DFU2GfInLQcqyxlos3+SDkvBDK5I2EmG5zi6qYTQuPHYBqMZHimqmwjkQc5Z3zbf5C8C/RnojvFEJlCRpLnBE+12ZyAcj7fLLzSUoGchlJXtQDcZopxRp1dovcKVhrVOcFKn8B9EHOkWYzqMoCE+tETILdjSoPL8XpE/VRqjbxFefan4QDBuYVshunbPBmhVRYyfsKqPzjAMK/zWzlAR1w7GDPADgTTgbHuS0YVXcox+soreFvxjZTS27E94unJZlJorYE7vS/BsBc5jA==","sha256sig":"e6PENxgZDTTtgpIsQnQSqyakd5IvmWk1Q5wMSYE9sxzJvTVSxUWThgN1wq28/6ZTFJuQ2DFU2GfInLQcqyxlos3+SDkvBDK5I2EmG5zi6qYTQuPHYBqMZHimqmwjkQc5Z3zbf5C8C/RnojvFEJlCRpLnBE+12ZyAcj7fLLzSUoGchlJXtQDcZopxRp1dovcKVhrVOcFKn8B9EHOkWYzqMoCE+tETILdjSoPL8XpE/VRqjbxFefan4QDBuYVshunbPBmhVRYyfsKqPzjAMK/zWzlAR1w7GDPADgTTgbHuS0YVXcox+soreFvxjZTS27E94unJZlJorYE7vS/BsBc5jA=="}'

# Write the full JSON including cert chain - use the original cmd approach via reg.exe
# First, save the full onboarding JSON from the decoded script
$b64Content = [IO.File]::ReadAllText('C:\tmp\mde-onboarding\onboarding_script_base64.txt').Trim()
$cmdContent = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64Content))

# Extract the OnboardingInfo JSON from the cmd script
if ($cmdContent -match '/v OnboardingInfo /t REG_SZ /f /d "(.+?)"') {
    $fullOnboardingJson = $Matches[1]
    Write-Host "[5/6] Extracted onboarding JSON (length: $($fullOnboardingJson.Length))"
} else {
    Write-Host "[5/6] ERROR: Could not extract onboarding JSON from script"
    exit 1
}
