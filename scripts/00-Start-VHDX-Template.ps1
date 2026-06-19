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

function Repair-PrepareScript {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "Script wurde nicht gefunden: $Path. Bitte erst den Download-Bootstrap ausfuehren."
    }

    $Content = Get-Content -Path $Path -Raw

    # Registry-New-Item auf ServerManager entfernen/ersetzen.
    $Content = $Content -replace 'New-Item\s+-Path\s+"HKLM:\\SOFTWARE\\Microsoft\\ServerManager"\s+-Force\s+\|\s+Out-Null', @'
$ServerManagerKey = "HKLM:\SOFTWARE\Microsoft\ServerManager"
if (-not (Test-Path $ServerManagerKey)) {
    New-Item -Path $ServerManagerKey | Out-Null
}
'@

    # Set-ItemProperty fuer ServerManager robust machen.
    $Content = $Content -replace 'Set-ItemProperty\s+-Path\s+"HKLM:\\SOFTWARE\\Microsoft\\ServerManager"\s+-Name\s+"DoNotOpenServerManagerAtLogon"\s+-Value\s+1\s+-Type\s+DWord', @'
New-ItemProperty `
    -Path $ServerManagerKey `
    -Name "DoNotOpenServerManagerAtLogon" `
    -Value 1 `
    -PropertyType DWord `
    -Force | Out-Null
'@

    # ExecutionPolicy darf durch GPO blockiert sein, daher nur soft setzen.
    $Content = $Content -replace 'Set-ExecutionPolicy\s+RemoteSigned\s+-Force', @'
try {
    Set-ExecutionPolicy RemoteSigned -Scope Process -Force -ErrorAction Stop
} catch {
    Write-Host "ExecutionPolicy konnte wegen Richtlinie nicht gesetzt werden. Script laeuft weiter." -ForegroundColor Yellow
}
'@

    Set-Content -Path $Path -Value $Content -Encoding UTF8 -Force
}

Repair-PrepareScript -Path $ScriptPath

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
