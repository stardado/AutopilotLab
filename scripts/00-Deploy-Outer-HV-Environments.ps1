# ============================================================
# 00-Deploy-Outer-HV-Environments.ps1
#
# Autopilot Hybrid Schulungssystem - Cluster Deployment
# Erstellt mehrere Nested-Hyper-V-Schulungsumgebungen.
#
# Abfragen:
# - VLAN ID
# - Anzahl Schulungsumgebungen, 1 bis 7
#
# Erstellt z. B.:
# - V450 DEMO-AP-HV-01
# - V450 DEMO-AP-HV-02
# - V450 DEMO-AP-HV-03
#
# Keine XGS/Firewall.
# ============================================================

function Read-NumberInRange {
    param (
        [string]$Prompt,
        [int]$Min,
        [int]$Max
    )

    do {
        $InputValue = Read-Host $Prompt

        if ($InputValue -match '^\d+$') {
            $Number = [int]$InputValue

            if ($Number -ge $Min -and $Number -le $Max) {
                return $Number
            }
        }

        Write-Host "Bitte eine Zahl zwischen $Min und $Max eingeben." -ForegroundColor Yellow
    } while ($true)
}

$VLAN = Read-NumberInRange -Prompt "VLAN ID" -Min 450 -Max 565
$EnvironmentCount = Read-NumberInRange -Prompt "Wie viele Schulungsumgebungen sollen erstellt werden? 1-7" -Min 1 -Max 7

# Ressourcen für jede Nested-Hyper-V VM
$HVMemory = 64GB
$HVCoreCount = 18

# Pfade aus eurem Standard-Deployment
$vSANschnellPath = "C:\ClusterStorage\SAN02-VOL02-SSD\VMs\"
$vNASBackupPath  = "C:\ClusterStorage\NAS01-VOL04-7.2K-R5\VMs\"
$ConfigPath      = "C:\ClusterStorage\SAN02-VOL02-SSD\VMs\"

# Eigenes Template für Autopilot-HV
$ServerTemplatePath = "C:\ClusterStorage\SAN02-VOL01-10K\Vorlagen\Autopilot-HV"
$ServerTemplate = "Autopilot-HV-Server2022-Template.vhdx"

$ClusterName = "ML-CL-11"
$SwitchName = "XG_Link"

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

function Get-HyperVHostForVLAN {
    param ([int]$VLAN)

    if ($VLAN -ge 450 -and $VLAN -le 546) {
        return "ML-HV-16"
    } elseif ($VLAN -ge 547 -and $VLAN -le 552) {
        return "ML-HV-19"
    } elseif ($VLAN -ge 553 -and $VLAN -le 558) {
        return "ML-HV-20"
    } elseif ($VLAN -ge 559 -and $VLAN -le 565) {
        return "ML-HV-21"
    } else {
        throw "Ungültige VLAN ID für Hyper-V Host Zuweisung: $VLAN"
    }
}

function Assert-PathExists {
    param (
        [string]$Path,
        [string]$Description
    )

    if (-not (Test-Path $Path)) {
        throw "$Description nicht gefunden: $Path"
    }
}

function Invoke-RobocopySafe {
    param (
        [string]$Source,
        [string]$Destination,
        [string]$FileName = ""
    )

    if ([string]::IsNullOrWhiteSpace($FileName)) {
        robocopy $Source $Destination /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
    } else {
        robocopy $Source $Destination $FileName /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
    }

    $ExitCode = $LASTEXITCODE

    if ($ExitCode -gt 7) {
        throw "Robocopy Fehler. ExitCode: $ExitCode"
    }
}

try {
    $HVHost = Get-HyperVHostForVLAN -VLAN $VLAN

    Write-Host ""
    Write-Host "Deployment-Übersicht" -ForegroundColor Cyan
    Write-Host "VLAN: $VLAN"
    Write-Host "Anzahl Schulungsumgebungen: $EnvironmentCount"
    Write-Host "Zielhost: $HVHost"
    Write-Host "RAM je Umgebung: $($HVMemory / 1GB) GB"
    Write-Host "CPU-Kerne je Umgebung: $HVCoreCount"
    Write-Host "Gesamt Start-RAM: $(($HVMemory / 1GB) * $EnvironmentCount) GB"
    Write-Host ""
} catch {
    Write-Error $_
    exit 1
}

try {
    Assert-PathExists -Path $ServerTemplatePath -Description "Servertemplate-Pfad"
    Assert-PathExists -Path "$ServerTemplatePath\$ServerTemplate" -Description "Servertemplate"
} catch {
    Write-Error $_
    exit 1
}

for ($i = 1; $i -le $EnvironmentCount; $i++) {
    $EnvironmentNumber = $i.ToString("00")
    $HVName = "V$VLAN DEMO-AP-HV-$EnvironmentNumber"

    $HVFolder = Join-Path $vSANschnellPath $HVName
    $HVVhdPath = Join-Path $HVFolder "$HVName.vhdx"

    $BackupFolder = Join-Path $vNASBackupPath $HVName
    $BackupDisk = Join-Path $BackupFolder "$HVName-Backup-1.vhdx"

    $MACIP = 100 + $i
    $HVMAC = Generate-MACAddress -VLAN $VLAN -MACIP $MACIP

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkGray
    Write-Host "Erstelle Umgebung $EnvironmentNumber von $EnvironmentCount" -ForegroundColor Cyan
    Write-Host "VM-Name: $HVName"
    Write-Host "MAC: $HVMAC"
    Write-Host "============================================================" -ForegroundColor DarkGray

    try {
        Write-Host "Kopiere Servertemplate für $HVName..." -ForegroundColor Cyan

        if (-not (Test-Path $HVFolder)) {
            New-Item -Path $HVFolder -ItemType Directory -Force | Out-Null
        }

        if (-not (Test-Path $HVVhdPath)) {
            Invoke-RobocopySafe -Source $ServerTemplatePath -Destination $HVFolder -FileName $ServerTemplate

            $CopiedTemplate = Join-Path $HVFolder $ServerTemplate

            if (-not (Test-Path $CopiedTemplate)) {
                throw "Kopiertes Servertemplate wurde nicht gefunden: $CopiedTemplate"
            }

            Rename-Item -Path $CopiedTemplate -NewName "$HVName.vhdx"
        } else {
            Write-Host "Ziel-VHDX existiert bereits, Kopieren wird übersprungen: $HVVhdPath" -ForegroundColor Yellow
        }
    } catch {
        Write-Error "Fehler beim Kopieren oder Umbenennen des Servertemplates für $HVName : $_"
        exit 1
    }

    try {
        Invoke-Command -ComputerName $HVHost -ScriptBlock {
            param (
                $HVName,
                $VLAN,
                $HVVhdPath,
                $ConfigPath,
                $HVMemory,
                $HVCoreCount,
                $HVMAC,
                $SwitchName,
                $BackupFolder,
                $BackupDisk,
                $ClusterName
            )

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

            if (Get-VM -Name $HVName -ErrorAction SilentlyContinue) {
                Write-Host "VM existiert bereits auf $env:COMPUTERNAME, wird übersprungen: $HVName" -ForegroundColor Yellow
                return
            }

            if (-not (Test-Path $HVVhdPath)) {
                throw "VHDX nicht gefunden: $HVVhdPath"
            }

            Write-Host "Erstelle Nested Hyper-V VM: $HVName"

            $VmConfigPath = Join-Path $ConfigPath $HVName

            New-VM -Name $HVName -Generation 2 -MemoryStartupBytes $HVMemory -Path $VmConfigPath -SwitchName $SwitchName | Out-Null

            Add-VMHardDiskDrive -VMName $HVName -Path $HVVhdPath

            Set-VMProcessor -VMName $HVName -Count $HVCoreCount -ExposeVirtualizationExtensions $true

            Set-VMNetworkAdapterVlan -VMName $HVName -Access -VlanId $VLAN

            $VmNetworkAdapter = Get-VMNetworkAdapter -VMName $HVName
            Set-VMNetworkAdapter -VMNetworkAdapter $VmNetworkAdapter -MacAddressSpoofing On
            Set-VMNetworkAdapter -VMNetworkAdapter $VmNetworkAdapter -StaticMacAddress $HVMAC

            Enable-IntegrationServiceSafe -VMName $HVName -PossibleNames @("Gastdienstschnittstelle", "Guest Service Interface")
            Disable-IntegrationServiceSafe -VMName $HVName -PossibleNames @("Zeitsynchronisierung", "Time Synchronization")

            Set-VMFirmware -VMName $HVName -FirstBootDevice (Get-VMHardDiskDrive -VMName $HVName | Select-Object -First 1)

            $VmHardDiskToResize = Get-VMHardDiskDrive -VMName $HVName | Select-Object -First 1
            Resize-VHD -Path $VmHardDiskToResize.Path -SizeBytes 250GB

            if (-not (Test-Path $BackupFolder)) {
                New-Item -Path $BackupFolder -ItemType Directory -Force | Out-Null
            }

            if (-not (Test-Path $BackupDisk)) {
                New-VHD -Path $BackupDisk -SizeBytes 1TB -Dynamic | Out-Null
            }

            Add-VMHardDiskDrive -VMName $HVName -Path $BackupDisk

            Set-VM -Name $HVName -Notes "Autopilot Hybrid Schulungssystem. Auf diesem Nested-Hyper-V laufen später DC01, WIN11-Normal und WIN11-OOBE."

            Start-VM $HVName

            try {
                Add-ClusterVirtualMachineRole -Cluster $ClusterName -Name $HVName -VirtualMachine $HVName -ErrorAction Stop | Out-Null
                Write-Host "$HVName wurde als Clusterrolle hinzugefügt."
            } catch {
                Write-Host "Hinweis: Clusterrolle für $HVName konnte nicht erstellt werden oder existiert bereits: $_" -ForegroundColor Yellow
            }

            Write-Host "$HVName wurde erfolgreich erstellt und als Nested Hyper-V vorbereitet." -ForegroundColor Green

        } -ArgumentList $HVName,$VLAN,$HVVhdPath,$ConfigPath,$HVMemory,$HVCoreCount,$HVMAC,$SwitchName,$BackupFolder,$BackupDisk,$ClusterName

    } catch {
        Write-Error "Fehler bei der Erstellung des Nested Hyper-V Hosts $HVName : $_"
        exit 1
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor DarkGray
Write-Host "Deployment abgeschlossen." -ForegroundColor Green
Write-Host "VLAN: $VLAN"
Write-Host "Anzahl Schulungsumgebungen: $EnvironmentCount"
Write-Host "Zielhost: $HVHost"
Write-Host "============================================================" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Erstellte bzw. geprüfte Umgebungen:" -ForegroundColor Cyan

for ($i = 1; $i -le $EnvironmentCount; $i++) {
    $EnvironmentNumber = $i.ToString("00")
    Write-Host "- V$VLAN DEMO-AP-HV-$EnvironmentNumber"
}

Write-Host ""
Write-Host "Nächster Schritt je Umgebung:"
Write-Host "1. Auf dem jeweiligen Nested-Hyper-V anmelden"
Write-Host "2. Bootstrap nach C:\Deploy laden"
Write-Host "3. C:\Deploy\scripts\01-Prepare-NestedHyperVHost.ps1 ausführen"
Write-Host "4. Danach innere VMs erstellen: DC01, WIN11-Normal, WIN11-OOBE"
