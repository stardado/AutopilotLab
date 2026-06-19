# ============================================================
# Install-AutopilotLabScripts.ps1
#
# Laedt alle Autopilot-Hybrid-Schulungsscripte aus Git zuerst
# lokal nach C:\Deploy.
#
# Nur Download. Es wird nichts gestartet, solange -RunPrepareHost
# nicht bewusst gesetzt wird.
# ============================================================

param (
    [string]$RawBaseUrl = "https://raw.githubusercontent.com/stardado/AutopilotLab/main/scripts",
    [string]$DeployRoot = "C:\Deploy",
    [string]$GitToken = "",
    [ValidateSet("None", "GitHub", "GitLab")]
    [string]$TokenType = "None",
    [switch]$RunPrepareHost
)

$ErrorActionPreference = "Stop"

$BootstrapPath = Join-Path $DeployRoot "bootstrap"
$ScriptsPath   = Join-Path $DeployRoot "scripts"
$LogsPath      = Join-Path $DeployRoot "logs"
$TempPath      = Join-Path $DeployRoot "temp"
$IsoPath       = Join-Path $DeployRoot "ISO"
$LogFile       = Join-Path $LogsPath "Install-AutopilotLabScripts.log"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

foreach ($Path in @($DeployRoot, $BootstrapPath, $ScriptsPath, $LogsPath, $TempPath, $IsoPath)) {
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

Start-Transcript -Path $LogFile -Force

Write-Host ""
Write-Host "Autopilot-Lab Bootstrap" -ForegroundColor Cyan
Write-Host "Quelle: $RawBaseUrl"
Write-Host "Ziel:   $DeployRoot"
Write-Host "ISO:    $IsoPath"
Write-Host ""

$Headers = @{}

if (-not [string]::IsNullOrWhiteSpace($GitToken)) {
    switch ($TokenType) {
        "GitHub" { $Headers["Authorization"] = "Bearer $GitToken" }
        "GitLab" { $Headers["PRIVATE-TOKEN"] = $GitToken }
        default { Write-Host "GitToken wurde angegeben, aber TokenType steht auf None. Token wird nicht verwendet." -ForegroundColor Yellow }
    }
}

$Scripts = @(
    "00-Deploy-Outer-HV-Environments.ps1",
    "00-Prepare-AutopilotHV-Template.ps1",
    "00-Start-VHDX-Template.ps1",
    "01-Prepare-NestedHyperVHost.ps1",
    "02-Create-InnerAutopilotVMs.ps1",
    "03-Setup-DC01-AutopilotHybrid.ps1",
    "04-Delegate-IntuneConnectorRights.ps1",
    "05-Get-AutopilotHash-OOBE.ps1",
    "06-Join-WIN11-Normal-ToDomain.ps1",
    "10-Start-DemoEnvironmentSetup.ps1"
)

function Get-GitRawFile {
    param (
        [string]$SourceUrl,
        [string]$Destination,
        [hashtable]$Headers
    )

    Write-Host "Lade:" -ForegroundColor Cyan
    Write-Host "  $SourceUrl"
    Write-Host "nach:"
    Write-Host "  $Destination"

    $Params = @{
        Uri = $SourceUrl
        OutFile = $Destination
        UseBasicParsing = $true
        ErrorAction = "Stop"
    }

    if ($Headers.Count -gt 0) {
        $Params.Headers = $Headers
    }

    Invoke-WebRequest @Params

    if (-not (Test-Path $Destination)) {
        throw "Download fehlgeschlagen: $Destination"
    }

    $FileInfo = Get-Item $Destination

    if ($FileInfo.Length -eq 0) {
        throw "Geladene Datei ist leer: $Destination"
    }

    Write-Host "OK: $($FileInfo.Name) ($($FileInfo.Length) Bytes)" -ForegroundColor Green
    Write-Host ""
}

function Repair-TemplateRegistryCode {
    param (
        [string]$TemplateScriptPath
    )

    if (-not (Test-Path $TemplateScriptPath)) {
        return
    }

    $Content = Get-Content -Path $TemplateScriptPath -Raw

    $OldBlock = @'
New-Item -Path "HKLM:\SOFTWARE\Microsoft\ServerManager" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager" -Name "DoNotOpenServerManagerAtLogon" -Value 1 -Type DWord
'@

    $NewBlock = @'
$ServerManagerKey = "HKLM:\SOFTWARE\Microsoft\ServerManager"

if (-not (Test-Path $ServerManagerKey)) {
    New-Item -Path $ServerManagerKey | Out-Null
}

New-ItemProperty `
    -Path $ServerManagerKey `
    -Name "DoNotOpenServerManagerAtLogon" `
    -Value 1 `
    -PropertyType DWord `
    -Force | Out-Null
'@

    if ($Content.Contains($OldBlock)) {
        $Content = $Content.Replace($OldBlock, $NewBlock)
        Set-Content -Path $TemplateScriptPath -Value $Content -Encoding UTF8 -Force
        Write-Host "Template-Script Registry-Fix angewendet: $TemplateScriptPath" -ForegroundColor Green
    } else {
        Write-Host "Template-Script Registry-Fix nicht noetig oder bereits vorhanden." -ForegroundColor Yellow
    }
}

foreach ($Script in $Scripts) {
    $SourceUrl = "$RawBaseUrl/$Script"
    $Destination = Join-Path $ScriptsPath $Script

    Get-GitRawFile -SourceUrl $SourceUrl -Destination $Destination -Headers $Headers
}

Repair-TemplateRegistryCode -TemplateScriptPath (Join-Path $ScriptsPath "00-Prepare-AutopilotHV-Template.ps1")

$ReadmePath = Join-Path $DeployRoot "README-AutopilotLab.txt"

$ReadmeContent = @"
Autopilot Hybrid Schulungssystem

Lokaler Deploy-Pfad:
$DeployRoot

Scripte:
$ScriptsPath

Logdateien:
$LogsPath

ISO-Pfad:
$IsoPath

VM-Pfad:
C:\AutopilotLab

Nur Download wurde ausgefuehrt.

VHDX/Golden-Image vorbereiten:
powershell.exe -ExecutionPolicy Bypass -File C:\Deploy\scripts\00-Start-VHDX-Template.ps1

VHDX/Golden-Image final mit Sysprep:
powershell.exe -ExecutionPolicy Bypass -File C:\Deploy\scripts\00-Start-VHDX-Template.ps1 -RunSysprep

Demo-/Schulungsumgebung starten:
powershell.exe -ExecutionPolicy Bypass -File C:\Deploy\scripts\10-Start-DemoEnvironmentSetup.ps1

ISOs fuer Demo-Setup:
C:\Deploy\ISO\WindowsServer2022.iso
C:\Deploy\ISO\Win11.iso
"@

Set-Content -Path $ReadmePath -Value $ReadmeContent -Encoding UTF8 -Force

Write-Host "README erstellt: $ReadmePath" -ForegroundColor Green

if ($RunPrepareHost) {
    $PrepareScript = Join-Path $ScriptsPath "01-Prepare-NestedHyperVHost.ps1"

    if (-not (Test-Path $PrepareScript)) {
        throw "Prepare-Script nicht gefunden: $PrepareScript"
    }

    Write-Host ""
    Write-Host "Starte Host-Vorbereitung..." -ForegroundColor Cyan

    & $PrepareScript -DeployRoot $DeployRoot -BasePath "C:\AutopilotLab" -IsoPath $IsoPath
}

Write-Host ""
Write-Host "Alle Scripte wurden nach C:\Deploy geladen." -ForegroundColor Green
Write-Host ""
Write-Host "Nur Download: abgeschlossen." -ForegroundColor Green
Write-Host ""
Write-Host "VHDX-Datei starten:"
Write-Host "powershell.exe -ExecutionPolicy Bypass -File C:\Deploy\scripts\00-Start-VHDX-Template.ps1"
Write-Host ""
Write-Host "Demo-Setup starten:"
Write-Host "powershell.exe -ExecutionPolicy Bypass -File C:\Deploy\scripts\10-Start-DemoEnvironmentSetup.ps1"
Write-Host ""

Stop-Transcript
