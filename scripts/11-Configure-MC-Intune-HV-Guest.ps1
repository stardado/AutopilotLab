# ============================================================
# 11-Configure-MC-Intune-HV-Guest.ps1
#
# Wird innerhalb eines MC-Intune-HV Nested-Hyper-V Hosts ausgefuehrt.
#
# Erkennt anhand der statischen Hyper-V-MAC-Adresse automatisch:
# - VLAN
# - laufende Nummer
# - Ziel-Hostname
# - statische IP-Konfiguration
#
# Beispiel:
# MAC 00:15:5D:55:51:01 -> VLAN 555 -> MC-Intune-HV-01
# IP 10.45.55.50/24, Gateway 10.45.55.254
#
# Installiert optional TeamViewer Host und setzt ein festes Kennwort.
# ============================================================

param (
    [int]$StartVLAN = 555,
    [ValidateRange(1,100)]
    [int]$EnvironmentCount = 7,
    [string]$HostNamePrefix = "MC-Intune-HV",
    [int]$IpHostOctet = 50,
    [int]$GatewayHostOctet = 254,
    [int]$PrefixLength = 24,
    [string[]]$DnsServers = @(),
    [string]$TeamViewerInstallerUrl = "https://download.teamviewer.com/download/TeamViewer_Host_Setup_x64.exe",
    [string]$TeamViewerInstallerPath = "C:\Deploy\Installers\TeamViewer_Host_Setup_x64.exe",
    [securestring]$TeamViewerPassword,
    [string]$TeamViewerPasswordPlain = "",
    [switch]$SkipTeamViewer,
    [switch]$Restart
)

$ErrorActionPreference = "Stop"

$DeployRoot = "C:\Deploy"
$LogRoot = Join-Path $DeployRoot "logs"
New-Item -ItemType Directory -Path $DeployRoot, $LogRoot, (Split-Path $TeamViewerInstallerPath -Parent) -Force | Out-Null

$LogFile = Join-Path $LogRoot "Configure-MC-Intune-HV-Guest.log"
Start-Transcript -Path $LogFile -Force

function Normalize-MacAddress {
    param ([string]$MacAddress)

    if ([string]::IsNullOrWhiteSpace($MacAddress)) {
        return ""
    }

    return ($MacAddress -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
}

function ConvertTo-PlainText {
    param ([securestring]$SecureString)

    if (-not $SecureString) {
        return ""
    }

    $Bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringAuto($Bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Bstr)
    }
}

function Convert-VlanToAddress {
    param (
        [int]$VLAN,
        [int]$HostOctet
    )

    $VlanText = $VLAN.ToString("000")
    $SecondOctet = "4$($VlanText.Substring(0,1))"
    $ThirdOctet = $VlanText.Substring(1,2)

    return "10.$SecondOctet.$ThirdOctet.$HostOctet"
}

function Get-McIntuneIdentityFromMac {
    param (
        [string]$NormalizedMac,
        [int]$StartVLAN,
        [int]$EnvironmentCount
    )

    # Erwartetes Schema aus dem Deployment:
    # Generate-MACAddress:
    # VLAN 555, MACIP 101 -> 00:15:5D:55:51:01
    # VLAN 556, MACIP 102 -> 00:15:5D:55:61:02
    # VLAN 561, MACIP 107 -> 00:15:5D:56:11:07

    if ($NormalizedMac -notmatch '^00155D([0-9A-F]{2})([0-9A-F]{2})([0-9A-F]{2})$') {
        return $null
    }

    $Part1 = $Matches[1]
    $Part2 = $Matches[2]
    $Part3 = $Matches[3]

    if ($Part1 -notmatch '^\d{2}$' -or $Part2 -notmatch '^\d{2}$' -or $Part3 -notmatch '^\d{2}$') {
        return $null
    }

    $DetectedVLAN = [int]("$Part1$($Part2.Substring(0,1))")
    $DetectedNumber = [int]$Part3

    $EndVLAN = $StartVLAN + $EnvironmentCount - 1

    if ($DetectedVLAN -lt $StartVLAN -or $DetectedVLAN -gt $EndVLAN) {
        return $null
    }

    if ($DetectedNumber -lt 1 -or $DetectedNumber -gt $EnvironmentCount) {
        return $null
    }

    return [pscustomobject]@{
        VLAN = $DetectedVLAN
        Number = $DetectedNumber
    }
}

function Find-McIntuneAdapter {
    param (
        [int]$StartVLAN,
        [int]$EnvironmentCount
    )

    $Adapters = Get-NetAdapter -Physical | Where-Object {
        $_.Status -ne "Disabled" -and -not [string]::IsNullOrWhiteSpace($_.MacAddress)
    }

    foreach ($Adapter in $Adapters) {
        $NormalizedMac = Normalize-MacAddress -MacAddress $Adapter.MacAddress
        $Identity = Get-McIntuneIdentityFromMac -NormalizedMac $NormalizedMac -StartVLAN $StartVLAN -EnvironmentCount $EnvironmentCount

        if ($Identity) {
            return [pscustomobject]@{
                Adapter = $Adapter
                NormalizedMac = $NormalizedMac
                VLAN = $Identity.VLAN
                Number = $Identity.Number
            }
        }
    }

    return $null
}

function Set-StaticIPv4Configuration {
    param (
        [Microsoft.Management.Infrastructure.CimInstance]$Adapter,
        [string]$IPAddress,
        [int]$PrefixLength,
        [string]$Gateway,
        [string[]]$DnsServers
    )

    Write-Host "Setze IPv4-Konfiguration auf Adapter $($Adapter.Name)..." -ForegroundColor Cyan
    Write-Host "IP: $IPAddress/$PrefixLength"
    Write-Host "Gateway: $Gateway"

    Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

    Get-NetRoute -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

    New-NetIPAddress `
        -InterfaceIndex $Adapter.ifIndex `
        -IPAddress $IPAddress `
        -PrefixLength $PrefixLength `
        -DefaultGateway $Gateway | Out-Null

    if (-not $DnsServers -or $DnsServers.Count -eq 0) {
        $DnsServers = @($Gateway)
    }

    Set-DnsClientServerAddress `
        -InterfaceIndex $Adapter.ifIndex `
        -ServerAddresses $DnsServers

    Write-Host "DNS: $($DnsServers -join ', ')"
}

function Install-TeamViewerHost {
    param (
        [string]$InstallerUrl,
        [string]$InstallerPath,
        [string]$PasswordPlain
    )

    Write-Host "" 
    Write-Host "TeamViewer Host Installation" -ForegroundColor Cyan

    if (-not (Test-Path $InstallerPath)) {
        Write-Host "Lade TeamViewer Host Installer..." -ForegroundColor Cyan
        Write-Host $InstallerUrl

        Invoke-WebRequest `
            -UseBasicParsing `
            -Uri $InstallerUrl `
            -OutFile $InstallerPath
    } else {
        Write-Host "TeamViewer Installer bereits vorhanden: $InstallerPath" -ForegroundColor Yellow
    }

    Write-Host "Installiere TeamViewer Host silent..." -ForegroundColor Cyan
    $InstallProcess = Start-Process `
        -FilePath $InstallerPath `
        -ArgumentList "/S" `
        -Wait `
        -PassThru

    Write-Host "TeamViewer Installer ExitCode: $($InstallProcess.ExitCode)"

    Start-Sleep -Seconds 10

    $TeamViewerExeCandidates = @(
        "$env:ProgramFiles\TeamViewer\TeamViewer.exe",
        "${env:ProgramFiles(x86)}\TeamViewer\TeamViewer.exe"
    )

    $TeamViewerExe = $TeamViewerExeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $TeamViewerExe) {
        throw "TeamViewer.exe wurde nach der Installation nicht gefunden."
    }

    Write-Host "TeamViewer.exe: $TeamViewerExe"

    if (-not [string]::IsNullOrWhiteSpace($PasswordPlain)) {
        Write-Host "Setze festes TeamViewer-Kennwort..." -ForegroundColor Cyan

        # Hinweis: Das Kennwort ist fuer den Moment des Aufrufs in der Prozessliste sichtbar.
        $PasswordProcess = Start-Process `
            -FilePath $TeamViewerExe `
            -ArgumentList @("--passwd", $PasswordPlain) `
            -Wait `
            -PassThru

        Write-Host "TeamViewer Passwort-CLI ExitCode: $($PasswordProcess.ExitCode)"
    } else {
        Write-Host "Kein TeamViewer-Kennwort angegeben. Passwortsetzung wird uebersprungen." -ForegroundColor Yellow
    }

    $TeamViewerService = Get-Service -Name "TeamViewer" -ErrorAction SilentlyContinue
    if ($TeamViewerService) {
        Set-Service -Name "TeamViewer" -StartupType Automatic
        Restart-Service -Name "TeamViewer" -Force -ErrorAction SilentlyContinue
    }
}

try {
    Write-Host ""
    Write-Host "MC Intune HV Guest-Konfiguration" -ForegroundColor Cyan
    Write-Host "Computer aktuell: $env:COMPUTERNAME"
    Write-Host "MAC-basierte Erkennung fuer VLAN $StartVLAN bis $($StartVLAN + $EnvironmentCount - 1)"
    Write-Host ""

    $Detected = Find-McIntuneAdapter -StartVLAN $StartVLAN -EnvironmentCount $EnvironmentCount

    if (-not $Detected) {
        Write-Host "Gefundene Adapter:" -ForegroundColor Yellow
        Get-NetAdapter -Physical | Select-Object Name, Status, MacAddress | Format-Table -AutoSize
        throw "Kein passender MC-Intune-HV Adapter anhand der MAC-Adresse gefunden."
    }

    $VLAN = $Detected.VLAN
    $Number = $Detected.Number
    $TargetHostName = "$HostNamePrefix-$($Number.ToString('00'))"
    $IPAddress = Convert-VlanToAddress -VLAN $VLAN -HostOctet $IpHostOctet
    $Gateway = Convert-VlanToAddress -VLAN $VLAN -HostOctet $GatewayHostOctet

    Write-Host "Erkannt:" -ForegroundColor Green
    Write-Host "Adapter: $($Detected.Adapter.Name)"
    Write-Host "MAC: $($Detected.Adapter.MacAddress)"
    Write-Host "VLAN: $VLAN"
    Write-Host "Nummer: $($Number.ToString('00'))"
    Write-Host "Ziel-Hostname: $TargetHostName"
    Write-Host "IP: $IPAddress/$PrefixLength"
    Write-Host "Gateway: $Gateway"
    Write-Host ""

    Set-StaticIPv4Configuration `
        -Adapter $Detected.Adapter `
        -IPAddress $IPAddress `
        -PrefixLength $PrefixLength `
        -Gateway $Gateway `
        -DnsServers $DnsServers

    $NeedsRestart = $false

    if ($env:COMPUTERNAME -ne $TargetHostName) {
        Write-Host "Benenne Computer um: $env:COMPUTERNAME -> $TargetHostName" -ForegroundColor Cyan
        Rename-Computer -NewName $TargetHostName -Force
        $NeedsRestart = $true
    } else {
        Write-Host "Hostname ist bereits korrekt: $TargetHostName" -ForegroundColor Green
    }

    if (-not $SkipTeamViewer) {
        if ([string]::IsNullOrWhiteSpace($TeamViewerPasswordPlain) -and -not $TeamViewerPassword) {
            $TeamViewerPassword = Read-Host "Festes TeamViewer-Kennwort" -AsSecureString
        }

        if ([string]::IsNullOrWhiteSpace($TeamViewerPasswordPlain)) {
            $TeamViewerPasswordPlain = ConvertTo-PlainText -SecureString $TeamViewerPassword
        }

        Install-TeamViewerHost `
            -InstallerUrl $TeamViewerInstallerUrl `
            -InstallerPath $TeamViewerInstallerPath `
            -PasswordPlain $TeamViewerPasswordPlain

        Clear-Variable TeamViewerPasswordPlain -ErrorAction SilentlyContinue
    } else {
        Write-Host "TeamViewer Installation wurde uebersprungen." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Konfiguration abgeschlossen." -ForegroundColor Green
    Write-Host "Hostname: $TargetHostName"
    Write-Host "IP: $IPAddress/$PrefixLength"
    Write-Host "Gateway: $Gateway"

    if ($NeedsRestart) {
        Write-Host ""
        Write-Host "Neustart erforderlich, damit der Hostname aktiv wird." -ForegroundColor Yellow

        if ($Restart) {
            Write-Host "Starte neu..." -ForegroundColor Yellow
            Stop-Transcript
            Restart-Computer -Force
            exit
        } else {
            Write-Host "Zum Neustart ausfuehren:" -ForegroundColor Cyan
            Write-Host "Restart-Computer -Force"
        }
    }
} catch {
    Write-Error $_
    Stop-Transcript
    exit 1
}

Stop-Transcript
