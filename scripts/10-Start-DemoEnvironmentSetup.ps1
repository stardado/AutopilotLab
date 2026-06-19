# ============================================================
# 10-Start-DemoEnvironmentSetup.ps1
#
# Starter fuer das eigentliche Aufsetzen der Demo-/Schulungsumgebung
# auf dem bereits ausgerollten Nested-Hyper-V.
#
# Macht:
# - Host vorbereiten: Hyper-V, AP-LAN, NAT, Ordner
# - wenn ISOs vorhanden sind: innere VMs erstellen
# - wenn ISOs fehlen: Hinweis ausgeben und stoppen
# ============================================================

param (
    [switch]$SkipVmCreation
)

$ErrorActionPreference = "Stop"

$PrepareScript = "C:\Deploy\scripts\01-Prepare-NestedHyperVHost.ps1"
$CreateVmScript = "C:\Deploy\scripts\02-Create-InnerAutopilotVMs.ps1"

$ServerIso = "C:\Deploy\ISO\WindowsServer2022.iso"
$Win11Iso = "C:\Deploy\ISO\Win11.iso"

if (-not (Test-Path $PrepareScript)) {
    throw "Prepare-Script wurde nicht gefunden: $PrepareScript. Bitte erst den Download-Bootstrap ausfuehren."
}

if (-not (Test-Path $CreateVmScript)) {
    throw "VM-Erstellungs-Script wurde nicht gefunden: $CreateVmScript. Bitte erst den Download-Bootstrap ausfuehren."
}

Write-Host ""
Write-Host "Starte Demo-/Schulungsumgebung Setup..." -ForegroundColor Cyan
Write-Host ""

& $PrepareScript

if ($SkipVmCreation) {
    Write-Host ""
    Write-Host "VM-Erstellung wurde durch -SkipVmCreation uebersprungen." -ForegroundColor Yellow
    exit
}

if (-not (Test-Path $ServerIso) -or -not (Test-Path $Win11Iso)) {
    Write-Host ""
    Write-Host "ISOs fehlen noch. Bitte ablegen:" -ForegroundColor Yellow
    Write-Host $ServerIso
    Write-Host $Win11Iso
    Write-Host ""
    Write-Host "Danach erneut starten:" -ForegroundColor Cyan
    Write-Host "powershell.exe -ExecutionPolicy Bypass -File C:\Deploy\scripts\10-Start-DemoEnvironmentSetup.ps1"
    exit
}

& $CreateVmScript
