# ============================================================
# 01-Prepare-NestedHyperVHost.ps1
#
# Bereitet den Nested-Hyper-V-Host vor.
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
    [string]$LabGatewayIp = "10.10.0.1",
    [int]$LabPrefixLength = 24,
    [string]$LabNatPrefix = "10.10.0.0/24",
    [string]$LabNatName = "NAT-AP-LAN",
    [string]$DataDriveLetter = "",
    [string]$DeployRoot = "C:\Deploy",
    [string]$BasePath = "C:\AutopilotLab",
    [string]$IsoPath = "C:\Deploy\ISO"
)

$ErrorActionPreference = "Stop"

$LogPath = Join-Path $DeployRoot "logs"
if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

Start-Transcript -Path "$LogPath\01-Prepare-NestedHyperVHost.log" -Force

Write-Host ""
Write-Host "Bereite Nested-Hyper-V-Host vor..." -ForegroundColor Cyan

# ============================================================
# Optionale Datenplatte vorbereiten
# Standard ist aus, weil VM-Daten auf C:\AutopilotLab liegen.
# Nur nutzen, wenn bewusst ein Laufwerksbuchstabe angegeben wird.
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

$HyperVFeature = Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue

if ($HyperVFeature -and -not $HyperVFeature.Installed) {
    Write-Host "Hyper-V Rolle ist nicht installiert. Installation wird gestartet..." -ForegroundColor Yellow
    Stop-Transcript
    Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart
    exit
}

if ($HyperVFeature -and $HyperVFeature.Installed) {
    Write-Host "Hyper-V Rolle ist bereits installiert." -ForegroundColor Green
}

Import-Module Hyper-V -ErrorAction Stop

if (-not (Get-VMSwitch -Name $LabSwitchName -ErrorAction SilentlyContinue)) {
    Write-Host "Erstelle internen vSwitch: $LabSwitchName" -ForegroundColor Cyan
    New-VMSwitch -Name $LabSwitchName -SwitchType Internal | Out-Null
} else {
    Write-Host "vSwitch existiert bereits: $LabSwitchName" -ForegroundColor Green
}

$InterfaceAlias = "vEthernet ($LabSwitchName)"

$ExistingIps = Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue

foreach ($Ip in $ExistingIps) {
    if ($Ip.IPAddress -ne $LabGatewayIp) {
        Remove-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $Ip.IPAddress -Confirm:$false -ErrorAction SilentlyContinue
    }
}

if (-not (Get-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $LabGatewayIp -ErrorAction SilentlyContinue)) {
    Write-Host "Setze Gateway-IP $LabGatewayIp auf $InterfaceAlias" -ForegroundColor Cyan
    New-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $LabGatewayIp -PrefixLength $LabPrefixLength | Out-Null
} else {
    Write-Host "Gateway-IP ist bereits gesetzt: $LabGatewayIp" -ForegroundColor Green
}

$ExistingNat = Get-NetNat -Name $LabNatName -ErrorAction SilentlyContinue

if (-not $ExistingNat) {
    Write-Host "Erstelle NAT: $LabNatName fuer $LabNatPrefix" -ForegroundColor Cyan
    New-NetNat -Name $LabNatName -InternalIPInterfaceAddressPrefix $LabNatPrefix | Out-Null
} else {
    Write-Host "NAT existiert bereits: $LabNatName" -ForegroundColor Green
}

Write-Host ""
Write-Host "Nested-Hyper-V-Host ist vorbereitet." -ForegroundColor Green
Write-Host "Deploy-Pfad: $DeployRoot"
Write-Host "Interner Lab-Switch: $LabSwitchName"
Write-Host "Gateway: $LabGatewayIp"
Write-Host "NAT: $LabNatName"
Write-Host "VM-Pfad: $BasePath\VMs"
Write-Host "VHDX-Pfad: $BasePath\VHDX"
Write-Host "ISO-Pfad: $IsoPath"
Write-Host ""
Write-Host "Bitte ISOs hier ablegen:"
Write-Host "- Windows Server ISO: $IsoPath\WindowsServer2022.iso"
Write-Host "- Windows 11 ISO:     $IsoPath\Win11.iso"
Write-Host ""
Write-Host "Danach ausfuehren:"
Write-Host "powershell.exe -ExecutionPolicy Bypass -File `"C:\Deploy\scripts\02-Create-InnerAutopilotVMs.ps1`""

Stop-Transcript
