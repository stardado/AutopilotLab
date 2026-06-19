# ============================================================
# 00-Start-VHDX-Template.ps1
#
# Starter fuer die VHDX-/Golden-Image-Vorbereitung.
# In der Template-Build-VM ausfuehren.
#
# Standardlauf ohne -RunSysprep prueft und bereitet nur vor.
# Mit -RunSysprep wird die VM generalisiert und heruntergefahren.
# ============================================================

param (
    [switch]$RunSysprep,
    [switch]$NoDesktopBootstrapStarter
)

$ErrorActionPreference = "Stop"

$ScriptPath = "C:\Deploy\scripts\00-Prepare-AutopilotHV-Template.ps1"

if (-not (Test-Path $ScriptPath)) {
    throw "Script wurde nicht gefunden: $ScriptPath. Bitte erst den Download-Bootstrap ausfuehren."
}

Write-Host ""
Write-Host "Starte VHDX-/Golden-Image-Vorbereitung..." -ForegroundColor Cyan
Write-Host "Script: $ScriptPath"
Write-Host ""

if ($RunSysprep) {
    Write-Host "Sysprep wird am Ende ausgefuehrt. Die VM faehrt danach herunter." -ForegroundColor Yellow
} else {
    Write-Host "Testlauf ohne Sysprep. Zum Finalisieren dieses Script mit -RunSysprep starten." -ForegroundColor Yellow
}

if ($NoDesktopBootstrapStarter -and $RunSysprep) {
    & $ScriptPath -RunSysprep
} elseif ($NoDesktopBootstrapStarter) {
    & $ScriptPath
} elseif ($RunSysprep) {
    & $ScriptPath -CreateDesktopBootstrapStarter -RunSysprep
} else {
    & $ScriptPath -CreateDesktopBootstrapStarter
}
