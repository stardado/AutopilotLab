# ============================================================
# 05-Get-AutopilotHash-OOBE.ps1
#
# Auf WIN11-OOBE im OOBE-Bildschirm ausführen.
# Ablauf:
# - SHIFT + F10
# - powershell
# - powershell.exe -ExecutionPolicy Bypass -File C:\Deploy\scripts\05-Get-AutopilotHash-OOBE.ps1
# ============================================================

param (
    [string]$GroupTag = "HYBRID-TRAINING",
    [string]$OutputPath = "C:\HWID",
    [string]$OutputFileName = "WIN11-OOBE-Autopilot.csv",
    [string]$DcShare = "\\10.10.0.10\AutopilotImport",
    [switch]$Online
)

$ErrorActionPreference = "Stop"

Set-ExecutionPolicy Bypass -Scope Process -Force
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Install-PackageProvider -Name NuGet -Force
Install-Script -Name Get-WindowsAutopilotInfo -Force

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

$CsvPath = Join-Path $OutputPath $OutputFileName

if ($Online) {
    Get-WindowsAutopilotInfo.ps1 -Online -GroupTag $GroupTag
} else {
    Get-WindowsAutopilotInfo.ps1 -OutputFile $CsvPath -GroupTag $GroupTag

    Write-Host ""
    Write-Host "Hardware Hash wurde erstellt:" -ForegroundColor Green
    Write-Host $CsvPath

    if (-not [string]::IsNullOrWhiteSpace($DcShare)) {
        Write-Host ""
        Write-Host "Versuche CSV nach DC01-Freigabe zu kopieren..." -ForegroundColor Cyan

        try {
            Copy-Item -Path $CsvPath -Destination (Join-Path $DcShare $OutputFileName) -Force
            Write-Host "CSV wurde kopiert nach: $DcShare\$OutputFileName" -ForegroundColor Green
        } catch {
            Write-Host "Kopieren auf DC-Freigabe nicht möglich: $_" -ForegroundColor Yellow
            Write-Host "CSV liegt lokal unter: $CsvPath" -ForegroundColor Yellow
        }
    }
}
