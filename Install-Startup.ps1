<#
Installs a shortcut in the current user's Startup folder so wrktmr launches
automatically at logon, hidden (no console window). Per-user Startup folder,
so no admin rights are required. Run once: right-click > Run with PowerShell,
or from a PowerShell prompt: .\Install-Startup.ps1
#>

$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$targetScript = Join-Path $scriptDir "TimeTracker.ps1"

if (-not (Test-Path $targetScript)) {
    throw "TimeTracker.ps1 not found next to Install-Startup.ps1 (expected: $targetScript)"
}

$startupDir   = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupDir "wrktmr.lnk"

$wsh = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($shortcutPath)
$shortcut.TargetPath       = (Get-Command powershell.exe).Source
$shortcut.Arguments        = "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$targetScript`""
$shortcut.WorkingDirectory = $scriptDir
$shortcut.WindowStyle      = 7  # minimized, belt-and-suspenders alongside -WindowStyle Hidden
$shortcut.Description      = "wrktmr - weekly work-hour tracker"
$shortcut.Save()

Write-Host "Installed startup shortcut: $shortcutPath"
Write-Host "wrktmr will launch automatically the next time you log in."
Write-Host ""
Write-Host "To start it right now without logging out/in, run:"
Write-Host "  powershell -WindowStyle Hidden -File `"$targetScript`""
