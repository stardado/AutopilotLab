# ============================================================
# 00-Deploy-MC-Intune-HV-Local-MLHV15.ps1
#
# Direkt-Deployment fuer ML-HV-15.
# Dieses Script wird direkt auf ML-HV-15 als Administrator ausgefuehrt.
#
# Erstellt standardmaessig 7 Nested-Hyper-V VMs:
# - V555 MC-Intune-HV-01
# - V556 MC-Intune-HV-02
# - V557 MC-Intune-HV-03
# - V558 MC-Intune-HV-04
# - V559 MC-Intune-HV-05
# - V560 MC-Intune-HV-06
# - V561 MC-Intune-HV-07
#
# Jede VM bekommt ein eigenes VLAN.
# Keine XGS/Firewall.
# ============================================================

param (
    [int]$StartVLAN = 555,
    [ValidateRange(1,7)]
    [int]$EnvironmentCount = 7,
    [string]$EnvironmentNamePrefix = "MC-Intune-HV",
    [string]$ClusterName = "ML-CL-11",
    [string]$SwitchName = "XG_Link",
    [string]$TemplatePath = "C:\ClusterStorage\SAN02-VOL01-10K\Vorlagen",
    [string]$TemplateFile = "WindowsServer2025Datacenter-100GB-Thin.vhdx",
    [string]$VmStoragePath = "C:\ClusterStorage\SAN02-VOL02-SSD\VMs\",
    [string]$BackupStoragePath = "C:\ClusterStorage\NAS01-VOL04-7.2K-R5\VMs\",
    [int64]$MemoryStartupBytes = 64GB,
    [int]$CpuCount = 18,
    [int64]$SystemDiskSize = 250GB,
    [int64]$BackupDiskSize = 1TB,
    [switch]$NoClusterRole,
    [switch]$NoStart
)

$ErrorActionPreference = "Stop"

function Generate-MACAddress {
    param (
        [int]$VLAN,
        [int]$MACIP
    )

    $VLANStr = $VLAN.ToString("000")
    $MACIPStr = $MACIP.ToString("000")

    $VLANPart1 = $VLANStr.Substring(0, 2)
    $VLANPart2 = $VLANStr.Substring(2, 1) + $MACIPStr.Substring(0, 1)
    $MACIPFormatted = $MACIPStr.Substring(1, 2)

    return "00:15:5D:" + $VLANPart1 + ":" + $VLANPart2 + ":" + $MACIPFormatted
}

function Invoke-RobocopySafe {
    param (
        [string]$Source,
        [string]$Destination,
        [string]$FileName
    )

    robocopy $Source $Destination $FileName /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null

    $ExitCode = $LASTEXITCODE

    if ($ExitCode -gt 7) {
        throw "Robocopy Fehler. ExitCode: $ExitCode"
    }
}

function Enable-IntegrationServiceSafe {
    param ([string]$VMName, [string[]]$PossibleNames)

    foreach ($Name in $PossibleNames) {
        $Service = Get-VMIntegrationService -VMName $VMName -Name $Name -ErrorAction SilentlyContinue
        if ($Service) {
            Enable-VMIntegrationService -VMName $VMName -Name $Name -ErrorAction SilentlyContinue
        }
    }
}

function Disable-IntegrationServiceSafe {
    param ([string]$VMName, [string[]]$PossibleNames)

    foreach ($Name in $PossibleNames) {
        $Service = Get-VMIntegrationService -VMName $VMName -Name $Name -ErrorAction SilentlyContinue
        if ($Service) {
            Disable-VMIntegrationService -VMName $VMName -Name $Name -ErrorAction SilentlyContinue
        }
    }
}

$EndVLAN = $StartVLAN + $EnvironmentCount - 1

if ($EndVLAN -gt 565) {
    throw "VLAN-Bereich ungueltig: $StartVLAN bis $EndVLAN. Maximal erlaubt: 565."
}

$TemplateFullPath = Join-Path $TemplatePath $TemplateFile

if (-not (Test-Path $TemplateFullPath)) {
    throw "Template-VHDX nicht gefunden: $TemplateFullPath"
}

if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "vSwitch nicht gefunden: $SwitchName"
}

Write-Host ""
Write-Host "MC Intune HV Direkt-Deployment auf $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host "Start-VLAN: $StartVLAN"
Write-Host "End-VLAN: $EndVLAN"
Write-Host "Anzahl: $EnvironmentCount"
Write-Host "Template: $TemplateFullPath"
Write-Host "VM-Storage: $VmStoragePath"
Write-Host "Backup-Storage: $BackupStoragePath"
Write-Host "Switch: $SwitchName"
Write-Host "RAM je VM: $($MemoryStartupBytes / 1GB) GB"
Write-Host "CPU je VM: $CpuCount"
Write-Host ""

Write-Host "Geplant:" -ForegroundColor Cyan
for ($i = 1; $i -le $EnvironmentCount; $i++) {
    $EnvironmentNumber = $i.ToString("00")
    $EnvironmentVLAN = $StartVLAN + $i - 1
    Write-Host "- V$EnvironmentVLAN $EnvironmentNamePrefix-$EnvironmentNumber"
}

Write-Host ""
$Confirm = Read-Host "Deployment auf $env:COMPUTERNAME starten? J/N"
if ($Confirm -notin @("J", "j", "Y", "y")) {
    Write-Host "Deployment abgebrochen." -ForegroundColor Yellow
    exit 0
}

for ($i = 1; $i -le $EnvironmentCount; $i++) {
    $EnvironmentNumber = $i.ToString("00")
    $EnvironmentVLAN = $StartVLAN + $i - 1
    $HVName = "V$EnvironmentVLAN $EnvironmentNamePrefix-$EnvironmentNumber"

    $HVFolder = Join-Path $VmStoragePath $HVName
    $HVVhdPath = Join-Path $HVFolder "$HVName.vhdx"

    $BackupFolder = Join-Path $BackupStoragePath $HVName
    $BackupDisk = Join-Path $BackupFolder "$HVName-Backup-1.vhdx"

    $MACIP = 100 + $i
    $HVMAC = Generate-MACAddress -VLAN $EnvironmentVLAN -MACIP $MACIP

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "Erstelle $HVName" -ForegroundColor Cyan
    Write-Host "VLAN: $EnvironmentVLAN"
    Write-Host "MAC: $HVMAC"
    Write-Host "============================================================" -ForegroundColor DarkGray

    if (Get-VM -Name $HVName -ErrorAction SilentlyContinue) {
        Write-Host "VM existiert bereits, wird uebersprungen: $HVName" -ForegroundColor Yellow
        continue
    }

    if (-not (Test-Path $HVFolder)) {
        New-Item -Path $HVFolder -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path $HVVhdPath)) {
        Write-Host "Kopiere Template-VHDX..." -ForegroundColor Cyan
        Invoke-RobocopySafe -Source $TemplatePath -Destination $HVFolder -FileName $TemplateFile

        $CopiedTemplate = Join-Path $HVFolder $TemplateFile
        if (-not (Test-Path $CopiedTemplate)) {
            throw "Kopierte VHDX nicht gefunden: $CopiedTemplate"
        }

        Rename-Item -Path $CopiedTemplate -NewName "$HVName.vhdx"
    }

    Write-Host "Erstelle VM..." -ForegroundColor Cyan
    New-VM -Name $HVName -Generation 2 -MemoryStartupBytes $MemoryStartupBytes -Path $HVFolder -SwitchName $SwitchName | Out-Null

    Add-VMHardDiskDrive -VMName $HVName -Path $HVVhdPath

    Set-VMProcessor -VMName $HVName -Count $CpuCount -ExposeVirtualizationExtensions $true

    Set-VMNetworkAdapterVlan -VMName $HVName -Access -VlanId $EnvironmentVLAN

    $VmNetworkAdapter = Get-VMNetworkAdapter -VMName $HVName
    Set-VMNetworkAdapter -VMNetworkAdapter $VmNetworkAdapter -MacAddressSpoofing On
    Set-VMNetworkAdapter -VMNetworkAdapter $VmNetworkAdapter -StaticMacAddress $HVMAC

    Enable-IntegrationServiceSafe -VMName $HVName -PossibleNames @("Gastdienstschnittstelle", "Guest Service Interface")
    Disable-IntegrationServiceSafe -VMName $HVName -PossibleNames @("Zeitsynchronisierung", "Time Synchronization")

    Set-VMFirmware -VMName $HVName -FirstBootDevice (Get-VMHardDiskDrive -VMName $HVName | Select-Object -First 1)

    $VmHardDiskToResize = Get-VMHardDiskDrive -VMName $HVName | Select-Object -First 1
    Resize-VHD -Path $VmHardDiskToResize.Path -SizeBytes $SystemDiskSize

    if (-not (Test-Path $BackupFolder)) {
        New-Item -Path $BackupFolder -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path $BackupDisk)) {
        New-VHD -Path $BackupDisk -SizeBytes $BackupDiskSize -Dynamic | Out-Null
    }

    Add-VMHardDiskDrive -VMName $HVName -Path $BackupDisk

    Set-VM -Name $HVName -Notes "MC Intune Schulungssystem. Nested-Hyper-V Host fuer DC01, WIN11-Normal und WIN11-OOBE. VLAN $EnvironmentVLAN."

    if (-not $NoStart) {
        Start-VM $HVName
    }

    if (-not $NoClusterRole) {
        try {
            Add-ClusterVirtualMachineRole -Cluster $ClusterName -Name $HVName -VirtualMachine $HVName -ErrorAction Stop | Out-Null
            Write-Host "$HVName wurde als Clusterrolle hinzugefuegt." -ForegroundColor Green
        } catch {
            Write-Host "Hinweis: Clusterrolle fuer $HVName konnte nicht erstellt werden oder existiert bereits: $_" -ForegroundColor Yellow
        }
    }

    Write-Host "$HVName wurde erstellt." -ForegroundColor Green
}

Write-Host ""
Write-Host "Deployment abgeschlossen." -ForegroundColor Green
for ($i = 1; $i -le $EnvironmentCount; $i++) {
    $EnvironmentNumber = $i.ToString("00")
    $EnvironmentVLAN = $StartVLAN + $i - 1
    Write-Host "- V$EnvironmentVLAN $EnvironmentNamePrefix-$EnvironmentNumber"
}
