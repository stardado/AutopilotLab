# ============================================================
# 05-Get-AutopilotHash-OOBE.ps1
#
# Auf WIN11-OOBE im OOBE-Bildschirm ausfuehren.
# Ablauf:
# - SHIFT + F10
# - powershell
# - Script laden/ausfuehren
#
# Erstellt den Autopilot Hardware Hash als CSV.
# Wenn keine DC-Freigabe angegeben wird, wird diese automatisch
# aus der aktuellen Client-IP abgeleitet:
# Beispiel Client 10.45.55.x -> \\10.45.55.10\AutopilotImport
# ============================================================

param (
    [string]$GroupTag = "HYBRID-TRAINING",
    [string]$OutputPath = "C:\HWID",
    [string]$OutputFileName = "WIN11-OOBE-Autopilot.csv",
    [string]$DcShare = "",
    [int]$DcHostOctet = 10,
    [switch]$Online
)

$ErrorActionPreference = "Stop"

function Get-PrimaryIPv4Address {
    $IPv4 = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -notlike "169.254*" -and
            $_.IPAddress -ne "127.0.0.1" -and
            $_.PrefixOrigin -ne "WellKnown"
        } |
        Sort-Object InterfaceMetric, InterfaceIndex |
        Select-Object -First 1

    if ($IPv4) {
        return $IPv4.IPAddress
    }

    return $null
}

function Get-AutoDcShare {
    param ([int]$DcHostOctet)

    $ClientIp = Get-PrimaryIPv4Address

    if ([string]::IsNullOrWhiteSpace($ClientIp)) {
        return ""
    }

    $Parts = $ClientIp.Split('.')
    if ($Parts.Count -ne 4) {
        return ""
    }

    $DcIp = "$($Parts[0]).$($Parts[1]).$($Parts[2]).$DcHostOctet"
    return "\\$DcIp\AutopilotImport"
}

Set-ExecutionPolicy Bypass -Scope Process -Force
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$CsvPath = Join-Path $OutputPath $OutputFileName

if ([string]::IsNullOrWhiteSpace($DcShare)) {
    $DcShare = Get-AutoDcShare -DcHostOctet $DcHostOctet
}

Write-Host ""
Write-Host "Autopilot Hardware Hash Export" -ForegroundColor Cyan
Write-Host "GroupTag: $GroupTag"
Write-Host "CSV: $CsvPath"
if (-not [string]::IsNullOrWhiteSpace($DcShare)) {
    Write-Host "DC-Freigabe: $DcShare"
} else {
    Write-Host "DC-Freigabe konnte nicht automatisch ermittelt werden." -ForegroundColor Yellow
}

Install-PackageProvider -Name NuGet -Force
Install-Script -Name Get-WindowsAutopilotInfo -Force

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
            Write-Host "Kopieren auf DC-Freigabe nicht moeglich: $_" -ForegroundColor Yellow
            Write-Host "CSV liegt lokal unter: $CsvPath" -ForegroundColor Yellow
        }
    }
}
