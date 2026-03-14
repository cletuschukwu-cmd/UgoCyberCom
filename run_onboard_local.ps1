Write-Host "=== Starting GCC High MDE Onboarding ==="

# Decode the onboarding script and extract the registry command
$b64 = Get-Content 'C:\tmp\mde-onboarding\onboarding_script_base64.txt' -Raw
$cmdContent = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64.Trim()))

# Save as .cmd file
$cmdPath = [System.IO.Path]::GetTempFileName() + ".cmd"
# Prepend auto-answer Y and remove pause
$modified = $cmdContent -replace 'set /p shouldContinue=.*', 'set shouldContinue=Y' -replace '(?m)^pause\s*$', 'rem pause'
$modified | Out-File -FilePath $cmdPath -Encoding ASCII

Write-Host "Saved onboarding script to: $cmdPath"
Write-Host "Executing onboarding..."
