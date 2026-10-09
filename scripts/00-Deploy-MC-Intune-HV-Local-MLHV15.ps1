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
# Keine XGS/Firewall. Keine Backup-Platte.
# ============================================================

param (
    [int]$StartVLAN = 555,
    [ValidateRange(1,7)]
    [int]$EnvironmentCount = 7,
    [int]$NumberBaseVLAN = 555,
    [string]$EnvironmentNamePrefix = "MC-Intune-HV",
    [string]$ClusterName = "ML-CL-11",
    [string]$SwitchName = "XG_Link",
    [string]$TemplatePath = "C:\ClusterStorage\SAN02-VOL01-10K\Vorlagen",
    [string]$TemplateFile = "WindowsServer2025Datacenter-100GB-Thin.vhdx",
    [string]$VmStoragePath = "C:\ClusterStorage\SAN02-VOL02-SSD\VMs\",
    [int64]$MemoryStartupBytes = 28GB,
    [int]$CpuCount = 16,
    [int64]$SystemDiskSize = 500GB,
    [switch]$NoClusterRole,
    [switch]$NoStart,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Write-Status {
    param (
        [string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message) -ForegroundColor $Color
}

function Write-Section {
    param ([string]$Message)

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Status $Message Cyan
    Write-Host "============================================================" -ForegroundColor DarkGray
}

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

function Get-EnvironmentNumber {
    param (
        [int]$VLAN,
        [int]$BaseVLAN
    )

    $Number = $VLAN - $BaseVLAN + 1

    if ($Number -lt 1) {
        throw "Ungueltige Nummerierung: VLAN $VLAN liegt vor Basis-VLAN $BaseVLAN."
    }

    return $Number.ToString("00")
}

function Invoke-RobocopySafe {
    param (
        [string]$Source,
        [string]$Destination,
        [string]$FileName
    )

    $SourceFile = Join-Path $Source $FileName
    $TargetFile = Join-Path $Destination $FileName

    if (-not (Test-Path $SourceFile)) {
        throw "Quelldatei fuer Robocopy nicht gefunden: $SourceFile"
    }

    $SourceItem = Get-Item $SourceFile
    Write-Status "Kopiere Template-VHDX per Robocopy..." Cyan
    Write-Status "Quelle: $SourceFile" Gray
    Write-Status "Ziel:   $TargetFile" Gray
    Write-Status ("Groesse: {0:N2} GB" -f ($SourceItem.Length / 1GB)) Gray
    Write-Status "Robocopy laeuft jetzt. Bei grossen VHDX kann das einige Minuten dauern." Yellow

    robocopy $Source $Destination $FileName /ETA /R:2 /W:5 /J

    $ExitCode = $LASTEXITCODE
    Write-Status "Robocopy beendet. ExitCode: $ExitCode" $(if ($ExitCode -gt 7) { [ConsoleColor]::Red } else { [ConsoleColor]::Green })

    if ($ExitCode -gt 7) {
        throw "Robocopy Fehler. ExitCode: $ExitCode"
    }

    if (-not (Test-Path $TargetFile)) {
        throw "Robocopy-Zieldatei wurde nicht gefunden: $TargetFile"
    }
}

function Enable-IntegrationServiceSafe {
    param ([string]$VMName, [string[]]$PossibleNames)

    foreach ($Name in $PossibleNames) {
        $Service = Get-VMIntegrationService -VMName $VMName -Name $Name -ErrorAction SilentlyContinue
        if ($Service) {
            Enable-VMIntegrationService -VMName $VMName -Name $Name -ErrorAction SilentlyContinue
            Write-Status "Integrationsdienst aktiviert: $Name" Green
        }
    }
}

function Disable-IntegrationServiceSafe {
    param ([string]$VMName, [string[]]$PossibleNames)

    foreach ($Name in $PossibleNames) {
        $Service = Get-VMIntegrationService -VMName $VMName -Name $Name -ErrorAction SilentlyContinue
        if ($Service) {
            Disable-VMIntegrationService -VMName $VMName -Name $Name -ErrorAction SilentlyContinue
            Write-Status "Integrationsdienst deaktiviert: $Name" Green
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

$LogRoot = "C:\Deploy\logs"
if (-not (Test-Path $LogRoot)) {
    New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
}

$TranscriptPath = Join-Path $LogRoot ("00-Deploy-MC-Intune-HV-Local-MLHV15-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
Start-Transcript -Path $TranscriptPath -Force | Out-Null

try {
    Write-Host ""
    Write-Status "MC Intune HV Direkt-Deployment auf $env:COMPUTERNAME" Cyan
    Write-Status "Start-VLAN: $StartVLAN"
    Write-Status "End-VLAN: $EndVLAN"
    Write-Status "Anzahl: $EnvironmentCount"
    Write-Status "Nummerierung ab VLAN: $NumberBaseVLAN"
    Write-Status "Template: $TemplateFullPath"
    Write-Status "VM-Storage: $VmStoragePath"
    Write-Status "Switch: $SwitchName"
    Write-Status "RAM je VM: $($MemoryStartupBytes / 1GB) GB"
    Write-Status "CPU je VM: $CpuCount"
    Write-Status "C-Laufwerk je VM: $($SystemDiskSize / 1GB) GB"
    Write-Status "Backup-Platte: nein"
    Write-Status "Log: $TranscriptPath"
    Write-Host ""

    Write-Host "Geplant:" -ForegroundColor Cyan
    for ($i = 1; $i -le $EnvironmentCount; $i++) {
        $EnvironmentVLAN = $StartVLAN + $i - 1
        $EnvironmentNumber = Get-EnvironmentNumber -VLAN $EnvironmentVLAN -BaseVLAN $NumberBaseVLAN
        Write-Host "- V$EnvironmentVLAN $EnvironmentNamePrefix-$EnvironmentNumber"
    }

    Write-Host ""
    if (-not $Force) {
        Write-Status "Warte auf Bestaetigung. Bitte J eingeben und Enter druecken." Yellow
        $Confirm = Read-Host "Deployment auf $env:COMPUTERNAME starten? J/N"
        if ($Confirm -notin @("J", "j", "Y", "y")) {
            Write-Status "Deployment abgebrochen." Yellow
            exit 0
        }
    } else {
        Write-Status "-Force gesetzt, Bestaetigung wird uebersprungen." Yellow
    }

    $StopwatchTotal = [System.Diagnostics.Stopwatch]::StartNew()

    for ($i = 1; $i -le $EnvironmentCount; $i++) {
        $EnvironmentVLAN = $StartVLAN + $i - 1
        $EnvironmentNumber = Get-EnvironmentNumber -VLAN $EnvironmentVLAN -BaseVLAN $NumberBaseVLAN
        $HVName = "V$EnvironmentVLAN $EnvironmentNamePrefix-$EnvironmentNumber"

        $Percent = [int]((($i - 1) / $EnvironmentCount) * 100)
        Write-Progress -Activity "MC Intune HV Deployment" -Status "$i/$EnvironmentCount - $HVName" -PercentComplete $Percent

        $StopwatchVM = [System.Diagnostics.Stopwatch]::StartNew()

        $HVFolder = Join-Path $VmStoragePath $HVName
        $HVVhdPath = Join-Path $HVFolder "$HVName.vhdx"

        $MACIP = 100 + ([int]$EnvironmentNumber)
        $HVMAC = Generate-MACAddress -VLAN $EnvironmentVLAN -MACIP $MACIP

        Write-Section "[$i/$EnvironmentCount] Bearbeite $HVName"
        Write-Status "VLAN: $EnvironmentVLAN"
        Write-Status "MAC: $HVMAC"
        Write-Status "VM-Ordner: $HVFolder"
        Write-Status "VHDX: $HVVhdPath"

        if (Get-VM -Name $HVName -ErrorAction SilentlyContinue) {
            Write-Status "VM existiert bereits, wird uebersprungen: $HVName" Yellow
            continue
        }

        if (-not (Test-Path $HVFolder)) {
            Write-Status "Erstelle VM-Ordner..." Cyan
            New-Item -Path $HVFolder -ItemType Directory -Force | Out-Null
            Write-Status "VM-Ordner erstellt." Green
        } else {
            Write-Status "VM-Ordner existiert bereits." Yellow
        }

        if (-not (Test-Path $HVVhdPath)) {
            $CopiedTemplate = Join-Path $HVFolder $TemplateFile

            if (-not (Test-Path $CopiedTemplate)) {
                Invoke-RobocopySafe -Source $TemplatePath -Destination $HVFolder -FileName $TemplateFile
            } else {
                Write-Status "Kopierte Template-Datei existiert bereits: $CopiedTemplate" Yellow
            }

            if (-not (Test-Path $CopiedTemplate)) {
                throw "Kopierte VHDX nicht gefunden: $CopiedTemplate"
            }

            Write-Status "Benenne VHDX um..." Cyan
            Rename-Item -Path $CopiedTemplate -NewName "$HVName.vhdx"
            Write-Status "VHDX bereit: $HVVhdPath" Green
        } else {
            Write-Status "Ziel-VHDX existiert bereits, Kopieren wird uebersprungen." Yellow
        }

        Write-Status "Erstelle VM-Huelle..." Cyan
        New-VM -Name $HVName -Generation 2 -MemoryStartupBytes $MemoryStartupBytes -Path $HVFolder -SwitchName $SwitchName | Out-Null
        Write-Status "VM-Huelle erstellt." Green

        Write-Status "Fuege System-VHDX hinzu..." Cyan
        Add-VMHardDiskDrive -VMName $HVName -Path $HVVhdPath
        Write-Status "System-VHDX hinzugefuegt." Green

        Write-Status "Setze CPU und Nested Virtualization..." Cyan
        Set-VMProcessor -VMName $HVName -Count $CpuCount -ExposeVirtualizationExtensions $true
        Write-Status "CPU gesetzt: $CpuCount vCPU, Nested Virtualization aktiv." Green

        Write-Status "Setze VLAN: $EnvironmentVLAN" Cyan
        Set-VMNetworkAdapterVlan -VMName $HVName -Access -VlanId $EnvironmentVLAN
        Write-Status "VLAN gesetzt." Green

        Write-Status "Setze MAC-Spoofing und statische MAC..." Cyan
        $VmNetworkAdapter = Get-VMNetworkAdapter -VMName $HVName
        Set-VMNetworkAdapter -VMNetworkAdapter $VmNetworkAdapter -MacAddressSpoofing On
        Set-VMNetworkAdapter -VMNetworkAdapter $VmNetworkAdapter -StaticMacAddress $HVMAC
        Write-Status "MAC-Spoofing aktiv, MAC gesetzt: $HVMAC" Green

        Write-Status "Setze Integrationsdienste..." Cyan
        Enable-IntegrationServiceSafe -VMName $HVName -PossibleNames @("Gastdienstschnittstelle", "Guest Service Interface")
        Disable-IntegrationServiceSafe -VMName $HVName -PossibleNames @("Zeitsynchronisierung", "Time Synchronization")

        Write-Status "Setze Bootdevice..." Cyan
        Set-VMFirmware -VMName $HVName -FirstBootDevice (Get-VMHardDiskDrive -VMName $HVName | Select-Object -First 1)
        Write-Status "Bootdevice gesetzt." Green

        Write-Status "Resize Systemdisk auf $($SystemDiskSize / 1GB) GB..." Cyan
        $VmHardDiskToResize = Get-VMHardDiskDrive -VMName $HVName | Select-Object -First 1
        Resize-VHD -Path $VmHardDiskToResize.Path -SizeBytes $SystemDiskSize
        Write-Status "Resize abgeschlossen." Green

        Write-Status "Setze Notizen..." Cyan
        Set-VM -Name $HVName -Notes "MC Intune Schulungssystem. Nested-Hyper-V Host fuer DC01, WIN11-Normal und WIN11-OOBE. VLAN $EnvironmentVLAN."
        Write-Status "Notizen gesetzt." Green

        if (-not $NoStart) {
            Write-Status "Starte VM..." Cyan
            Start-VM $HVName
            Write-Status "VM gestartet." Green
        } else {
            Write-Status "VM-Start wurde mit -NoStart uebersprungen." Yellow
        }

        if (-not $NoClusterRole) {
            Write-Status "Fuege VM als Clusterrolle hinzu..." Cyan
            try {
                Add-ClusterVirtualMachineRole -Cluster $ClusterName -Name $HVName -VirtualMachine $HVName -ErrorAction Stop | Out-Null
                Write-Status "$HVName wurde als Clusterrolle hinzugefuegt." Green
            } catch {
                Write-Status "Hinweis: Clusterrolle fuer $HVName konnte nicht erstellt werden oder existiert bereits: $_" Yellow
            }
        } else {
            Write-Status "Clusterrolle wurde mit -NoClusterRole uebersprungen." Yellow
        }

        $StopwatchVM.Stop()
        Write-Status "$HVName wurde fertig erstellt. Dauer: $($StopwatchVM.Elapsed.ToString())" Green
    }

    Write-Progress -Activity "MC Intune HV Deployment" -Completed
    $StopwatchTotal.Stop()

    Write-Host ""
    Write-Status "Deployment abgeschlossen. Gesamtdauer: $($StopwatchTotal.Elapsed.ToString())" Green
    for ($i = 1; $i -le $EnvironmentCount; $i++) {
        $EnvironmentVLAN = $StartVLAN + $i - 1
        $EnvironmentNumber = Get-EnvironmentNumber -VLAN $EnvironmentVLAN -BaseVLAN $NumberBaseVLAN
        Write-Host "- V$EnvironmentVLAN $EnvironmentNamePrefix-$EnvironmentNumber"
    }
} finally {
    Stop-Transcript | Out-Null
}
