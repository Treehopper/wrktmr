<#
Removes the wrktmr Startup folder shortcut installed by Install-Startup.ps1.
Does not stop an already-running instance - use the tray icon's Exit menu
item for that.
#>

$startupDir   = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupDir "wrktmr.lnk"

if (Test-Path $shortcutPath) {
    Remove-Item $shortcutPath -Force
    Write-Host "Removed startup shortcut: $shortcutPath"
} else {
    Write-Host "No startup shortcut found at: $shortcutPath"
}
