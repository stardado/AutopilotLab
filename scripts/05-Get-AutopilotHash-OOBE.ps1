# ============================================================
# 05-Get-AutopilotHash-OOBE.ps1
#
# Auf dem installierten WIN11-OOBE-Rechner ausfuehren.
#
# Ablauf:
# - Autopilot Hardware Hash erzeugen
# - CSV auf den Desktop des aeusseren Hyper-V-Hosts kopieren
# - Kopie pruefen
# - Nur bei erfolgreicher Pruefung Sysprep /oobe /shutdown ausfuehren
#
# Zielschema:
#   Client-IP 10.45.55.x -> Hyper-V-Host 10.45.55.50
#   Zielpfad auf dem Host: C:\Users\Administrator\Desktop
# ============================================================

param (
    [string]$GroupTag = "HYBRID-TRAINING",
    [string]$OutputPath = "C:\HWID",
    [string]$OutputFileName = "WIN11-OOBE-Autopilot.csv",
    [int]$HyperVHostOctet = 50,
    [string]$TargetUser = "Administrator",
    [string]$TargetDesktopRelativePath = "Users\Administrator\Desktop",
    [switch]$NoCopy,
    [switch]$NoSysprep,
    [switch]$Online
)

$ErrorActionPreference = "Stop"

function Get-PrimaryIPv4Address {
    $IPv4 = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -like "10.*" -and
            $_.IPAddress -notlike "169.254*" -and
            $_.IPAddress -ne "127.0.0.1"
        } |
        Sort-Object InterfaceMetric, InterfaceIndex |
        Select-Object -First 1

    if (-not $IPv4) {
        throw "Keine passende 10.x.x.x IPv4-Adresse gefunden."
    }

    return $IPv4.IPAddress
}

function Get-HyperVHostTarget {
    param ([int]$HostOctet)

    $ClientIp = Get-PrimaryIPv4Address
    $Parts = $ClientIp.Split('.')

    if ($Parts.Count -ne 4) {
        throw "Ungueltige IPv4-Adresse erkannt: $ClientIp"
    }

    $HostIp = "$($Parts[0]).$($Parts[1]).$($Parts[2]).$HostOctet"

    return [pscustomobject]@{
        ClientIp = $ClientIp
        HostIp = $HostIp
        AdminShare = "\\$HostIp\C$"
    }
}

function Install-AutopilotScript {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    try {
        Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    } catch {
        Write-Host "PSGallery konnte nicht auf Trusted gesetzt werden: $_" -ForegroundColor Yellow
    }

    Install-PackageProvider -Name NuGet -Force | Out-Null
    Install-Script -Name Get-WindowsAutopilotInfo -Force
}

function New-ConsoleCredential {
    param (
        [string]$TargetUser,
        [string]$AdminShare
    )

    Write-Host ""
    Write-Host "Zugang fuer $AdminShare" -ForegroundColor Cyan
    Write-Host "Benutzer: $TargetUser"
    $SecureSecret = Read-Host "Kennwort eingeben" -AsSecureString

    return New-Object System.Management.Automation.PSCredential ($TargetUser, $SecureSecret)
}

function Copy-And-VerifyCsvToHyperVHost {
    param (
        [string]$CsvPath,
        [string]$OutputFileName,
        [object]$Target,
        [string]$TargetUser,
        [string]$TargetDesktopRelativePath
    )

    if (-not (Test-Path $CsvPath)) {
        throw "Lokale CSV wurde nicht gefunden: $CsvPath"
    }

    $LocalFile = Get-Item $CsvPath
    if ($LocalFile.Length -le 0) {
        throw "Lokale CSV ist leer: $CsvPath"
    }

    Write-Host ""
    Write-Host "Kopiere CSV auf Hyper-V-Host..." -ForegroundColor Cyan
    Write-Host "Client-IP: $($Target.ClientIp)"
    Write-Host "Hyper-V-Host: $($Target.HostIp)"
    Write-Host "Admin-Share: $($Target.AdminShare)"

    $Credential = New-ConsoleCredential -TargetUser $TargetUser -AdminShare $Target.AdminShare
    $DriveName = "HV" + ([guid]::NewGuid().ToString("N").Substring(0, 8))

    try {
        New-PSDrive -Name $DriveName -PSProvider FileSystem -Root $Target.AdminShare -Credential $Credential -ErrorAction Stop | Out-Null

        $RemoteDesktop = "$DriveName`:\$TargetDesktopRelativePath"
        $RemoteCsvPath = Join-Path $RemoteDesktop $OutputFileName

        if (-not (Test-Path $RemoteDesktop)) {
            throw "Desktop-Zielpfad nicht gefunden: $RemoteDesktop"
        }

        Copy-Item -Path $CsvPath -Destination $RemoteCsvPath -Force

        if (-not (Test-Path $RemoteCsvPath)) {
            throw "Remote-CSV wurde nach dem Kopieren nicht gefunden: $RemoteCsvPath"
        }

        $RemoteFile = Get-Item $RemoteCsvPath
        if ($RemoteFile.Length -ne $LocalFile.Length) {
            throw "Remote-CSV Groesse stimmt nicht. Lokal: $($LocalFile.Length), Remote: $($RemoteFile.Length)"
        }

        Write-Host "CSV erfolgreich kopiert und geprueft." -ForegroundColor Green
        Write-Host "Ziel: \\$($Target.HostIp)\C$\$TargetDesktopRelativePath\$OutputFileName"
        return $true
    } finally {
        Remove-PSDrive -Name $DriveName -Force -ErrorAction SilentlyContinue
    }
}

function Start-OobeSysprep {
    $Sysprep = "C:\Windows\System32\Sysprep\Sysprep.exe"

    if (-not (Test-Path $Sysprep)) {
        throw "Sysprep wurde nicht gefunden: $Sysprep"
    }

    Write-Host ""
    Write-Host "Starte Sysprep: /oobe /shutdown" -ForegroundColor Yellow
    Start-Process -FilePath $Sysprep -ArgumentList "/oobe /shutdown" -Wait
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$CsvPath = Join-Path $OutputPath $OutputFileName

Write-Host ""
Write-Host "Autopilot Hardware Hash Export" -ForegroundColor Cyan
Write-Host "GroupTag: $GroupTag"
Write-Host "CSV lokal: $CsvPath"

Install-AutopilotScript

if ($Online) {
    Get-WindowsAutopilotInfo.ps1 -Online -GroupTag $GroupTag
    Write-Host "Online-Upload wurde angestossen. Sysprep wird bei -Online nicht automatisch gestartet." -ForegroundColor Yellow
    exit
}

Get-WindowsAutopilotInfo.ps1 -OutputFile $CsvPath -GroupTag $GroupTag

Write-Host ""
Write-Host "Hardware Hash wurde lokal erstellt:" -ForegroundColor Green
Write-Host $CsvPath

$Verified = $false

if ($NoCopy) {
    Write-Host "Kopieren wurde mit -NoCopy uebersprungen." -ForegroundColor Yellow
} else {
    $Target = Get-HyperVHostTarget -HostOctet $HyperVHostOctet
    $Verified = Copy-And-VerifyCsvToHyperVHost `
        -CsvPath $CsvPath `
        -OutputFileName $OutputFileName `
        -Target $Target `
        -TargetUser $TargetUser `
        -TargetDesktopRelativePath $TargetDesktopRelativePath
}

if ($NoSysprep) {
    Write-Host "Sysprep wurde mit -NoSysprep uebersprungen." -ForegroundColor Yellow
    exit
}

if (-not $Verified) {
    throw "CSV wurde nicht erfolgreich auf den Hyper-V-Host kopiert/geprueft. Sysprep wird nicht gestartet."
}

Start-OobeSysprep
