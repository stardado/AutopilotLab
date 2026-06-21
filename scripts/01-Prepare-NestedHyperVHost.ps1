# ============================================================
# 01-Prepare-NestedHyperVHost.ps1
#
# Bereitet den Nested-Hyper-V-Host vor.
#
# Wichtig:
# - Kein interner NAT-Switch mehr.
# - AP-LAN wird als externer vSwitch auf dem bestehenden
#   Management-/Ethernet-Adapter erstellt.
# - Die bereits gesetzte Host-IP wird vorher gesichert und
#   danach auf vEthernet(AP-LAN) wiederhergestellt.
#
# Scripte/Logs/ISOs:
#   C:\Deploy
#   C:\Deploy\ISO
#
# VM-Daten:
#   C:\AutopilotLab
# ============================================================

param (
    [string]$LabSwitchName = "AP-LAN",
    [string]$ExternalAdapterName = "",
    [string]$DataDriveLetter = "",
    [string]$DeployRoot = "C:\Deploy",
    [string]$BasePath = "C:\AutopilotLab",
    [string]$IsoPath = "C:\Deploy\ISO"
)

$ErrorActionPreference = "Stop"

function Test-HyperVInstalled {
    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
        $Feature = Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue
        if ($Feature) {
            return [bool]$Feature.Installed
        }
    }

    if (Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
        $FeatureNames = @("Microsoft-Hyper-V-All", "Microsoft-Hyper-V")

        foreach ($FeatureName in $FeatureNames) {
            $Feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction SilentlyContinue
            if ($Feature -and $Feature.State -eq "Enabled") {
                return $true
            }
        }
    }

    if (Get-Module -ListAvailable -Name Hyper-V) {
        return $true
    }

    return $false
}

function Install-HyperVFeature {
    if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
        Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart
        return
    }

    if (Get-Command Enable-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
        $FeatureNames = @("Microsoft-Hyper-V-All", "Microsoft-Hyper-V")

        foreach ($FeatureName in $FeatureNames) {
            $Feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction SilentlyContinue
            if ($Feature) {
                Enable-WindowsOptionalFeature -Online -FeatureName $FeatureName -All -NoRestart
                Write-Host "Hyper-V wurde aktiviert. Bitte Server neu starten und das Script erneut ausfuehren." -ForegroundColor Yellow
                return
            }
        }
    }

    throw "Hyper-V konnte nicht installiert werden. Weder Install-WindowsFeature noch passende WindowsOptionalFeature wurden gefunden."
}

function Get-PrimaryNetworkAdapter {
    param ([string]$PreferredName)

    if (-not [string]::IsNullOrWhiteSpace($PreferredName)) {
        $Adapter = Get-NetAdapter -Name $PreferredName -ErrorAction SilentlyContinue
        if ($Adapter) {
            return $Adapter
        }

        throw "Angegebener Netzwerkadapter wurde nicht gefunden: $PreferredName"
    }

    $DefaultRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric, InterfaceMetric |
        Select-Object -First 1

    if ($DefaultRoute) {
        $Adapter = Get-NetAdapter -InterfaceIndex $DefaultRoute.InterfaceIndex -ErrorAction SilentlyContinue
        if ($Adapter -and $Adapter.Name -notlike "vEthernet*") {
            return $Adapter
        }
    }

    $UpAdapter = Get-NetAdapter -Physical | Where-Object {
        $_.Status -eq "Up" -and $_.Name -notlike "vEthernet*"
    } | Sort-Object ifIndex | Select-Object -First 1

    if ($UpAdapter) {
        return $UpAdapter
    }

    throw "Kein geeigneter physischer Netzwerkadapter fuer den externen vSwitch gefunden."
}

function Get-AdapterIPv4Config {
    param ([Microsoft.Management.Infrastructure.CimInstance]$Adapter)

    $IPv4 = Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "169.254*" } |
        Select-Object -First 1

    $Gateway = Get-NetRoute -InterfaceIndex $Adapter.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric |
        Select-Object -First 1

    $Dns = Get-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        IPAddress = if ($IPv4) { $IPv4.IPAddress } else { $null }
        PrefixLength = if ($IPv4) { $IPv4.PrefixLength } else { $null }
        Gateway = if ($Gateway) { $Gateway.NextHop } else { $null }
        DnsServers = if ($Dns) { $Dns.ServerAddresses } else { @() }
    }
}

function Restore-AdapterIPv4Config {
    param (
        [string]$InterfaceAlias,
        [object]$Config
    )

    if (-not $Config -or [string]::IsNullOrWhiteSpace($Config.IPAddress)) {
        Write-Host "Keine statische IPv4-Konfiguration zum Wiederherstellen gefunden." -ForegroundColor Yellow
        return
    }

    Write-Host "Stelle Host-IP auf $InterfaceAlias wieder her..." -ForegroundColor Cyan
    Write-Host "IP: $($Config.IPAddress)/$($Config.PrefixLength)"
    Write-Host "Gateway: $($Config.Gateway)"
    Write-Host "DNS: $($Config.DnsServers -join ', ')"

    Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

    Get-NetRoute -InterfaceAlias $InterfaceAlias -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

    if ([string]::IsNullOrWhiteSpace($Config.Gateway)) {
        New-NetIPAddress `
            -InterfaceAlias $InterfaceAlias `
            -IPAddress $Config.IPAddress `
            -PrefixLength $Config.PrefixLength | Out-Null
    } else {
        New-NetIPAddress `
            -InterfaceAlias $InterfaceAlias `
            -IPAddress $Config.IPAddress `
            -PrefixLength $Config.PrefixLength `
            -DefaultGateway $Config.Gateway | Out-Null
    }

    if ($Config.DnsServers -and $Config.DnsServers.Count -gt 0) {
        Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -ServerAddresses $Config.DnsServers
    }
}

$LogPath = Join-Path $DeployRoot "logs"
if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

Start-Transcript -Path "$LogPath\01-Prepare-NestedHyperVHost.log" -Force

Write-Host ""
Write-Host "Bereite Nested-Hyper-V-Host vor..." -ForegroundColor Cyan

# ============================================================
# Optionale Datenplatte vorbereiten
# ============================================================

if (-not [string]::IsNullOrWhiteSpace($DataDriveLetter)) {
    $ExistingVolume = Get-Volume -DriveLetter $DataDriveLetter -ErrorAction SilentlyContinue

    if (-not $ExistingVolume) {
        Write-Host "Kein Laufwerk $DataDriveLetter`: gefunden. Suche RAW-Datentraeger..." -ForegroundColor Yellow

        $RawDisk = Get-Disk |
            Where-Object { $_.PartitionStyle -eq "RAW" -and $_.OperationalStatus -eq "Online" } |
            Sort-Object Number |
            Select-Object -First 1

        if ($RawDisk) {
            Write-Host "Initialisiere Datentraeger $($RawDisk.Number) als $DataDriveLetter`: ..." -ForegroundColor Cyan

            Initialize-Disk -Number $RawDisk.Number -PartitionStyle GPT

            New-Partition -DiskNumber $RawDisk.Number -UseMaximumSize -DriveLetter $DataDriveLetter |
                Format-Volume -FileSystem NTFS -NewFileSystemLabel "AutopilotLabData" -Confirm:$false
        } else {
            Write-Host "Kein RAW-Datentraeger gefunden. Verwende vorhandene Pfade, sofern moeglich." -ForegroundColor Yellow
        }
    } else {
        Write-Host "Laufwerk $DataDriveLetter`: ist vorhanden." -ForegroundColor Green
    }
} else {
    Write-Host "Datenplatten-Initialisierung uebersprungen. VM-Daten liegen unter $BasePath." -ForegroundColor Green
}

$Folders = @(
    $DeployRoot,
    "$DeployRoot\bootstrap",
    "$DeployRoot\scripts",
    "$DeployRoot\logs",
    "$DeployRoot\temp",
    $IsoPath,
    $BasePath,
    "$BasePath\VMs",
    "$BasePath\VHDX",
    "$BasePath\Export"
)

foreach ($Folder in $Folders) {
    if (-not (Test-Path $Folder)) {
        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
        Write-Host "Ordner erstellt: $Folder" -ForegroundColor Green
    }
}

if (-not (Test-HyperVInstalled)) {
    Write-Host "Hyper-V ist nicht installiert. Installation/Aktivierung wird gestartet..." -ForegroundColor Yellow
    Stop-Transcript
    Install-HyperVFeature
    exit
}

Write-Host "Hyper-V ist installiert oder das Hyper-V-Modul ist verfuegbar." -ForegroundColor Green

Import-Module Hyper-V -ErrorAction Stop

$ExistingSwitch = Get-VMSwitch -Name $LabSwitchName -ErrorAction SilentlyContinue

if ($ExistingSwitch) {
    Write-Host "vSwitch existiert bereits: $LabSwitchName ($($ExistingSwitch.SwitchType))" -ForegroundColor Green

    if ($ExistingSwitch.SwitchType -ne "External") {
        Write-Host "WARNUNG: $LabSwitchName ist kein externer Switch. Fuer Internet der inneren VMs sollte er External sein." -ForegroundColor Yellow
    }
} else {
    $PrimaryAdapter = Get-PrimaryNetworkAdapter -PreferredName $ExternalAdapterName
    $HostIpConfig = Get-AdapterIPv4Config -Adapter $PrimaryAdapter

    Write-Host "Erstelle externen vSwitch: $LabSwitchName" -ForegroundColor Cyan
    Write-Host "Adapter: $($PrimaryAdapter.Name)"

    New-VMSwitch `
        -Name $LabSwitchName `
        -NetAdapterName $PrimaryAdapter.Name `
        -AllowManagementOS $true | Out-Null

    Start-Sleep -Seconds 5

    $VSwitchInterfaceAlias = "vEthernet ($LabSwitchName)"
    Restore-AdapterIPv4Config -InterfaceAlias $VSwitchInterfaceAlias -Config $HostIpConfig
}

Write-Host ""
Write-Host "Nested-Hyper-V-Host ist vorbereitet." -ForegroundColor Green
Write-Host "Deploy-Pfad: $DeployRoot"
Write-Host "Externer Lab-Switch: $LabSwitchName"
Write-Host "VM-Pfad: $BasePath\VMs"
Write-Host "VHDX-Pfad: $BasePath\VHDX"
Write-Host "ISO-Pfad: $IsoPath"
Write-Host ""
Write-Host "Bitte ISOs hier ablegen:"
Write-Host "- Windows Server 2025 ISO: $IsoPath\WindowsServer2025.iso"
Write-Host "- Windows 11 ISO:          $IsoPath\Win11.iso"
Write-Host ""
Write-Host "Danach ausfuehren:"
Write-Host "powershell.exe -ExecutionPolicy Bypass -File `"C:\Deploy\scripts\02-Create-InnerAutopilotVMs.ps1`""

Stop-Transcript
