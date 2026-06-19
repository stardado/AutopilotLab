# ============================================================
# 02-Create-InnerAutopilotVMs.ps1
#
# Erstellt die inneren Schulungs-VMs:
# - DC01
# - WIN11-Normal
# - WIN11-OOBE
#
# VM-Daten:
#   C:\AutopilotLab
#
# ISOs:
#   C:\Deploy\ISO
# ============================================================

param (
    [string]$LabSwitchName = "AP-LAN",
    [string]$DeployRoot = "C:\Deploy",
    [string]$BasePath = "C:\AutopilotLab",
    [string]$VMPath = "C:\AutopilotLab\VMs",
    [string]$VHDXPath = "C:\AutopilotLab\VHDX",
    [string]$ServerIso = "C:\Deploy\ISO\WindowsServer2022.iso",
    [string]$Win11Iso = "C:\Deploy\ISO\Win11.iso"
)

$ErrorActionPreference = "Stop"

function Assert-HyperVReady {
    if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
        throw "Das Hyper-V PowerShell-Modul wurde nicht gefunden. Bitte zuerst 01-Prepare-NestedHyperVHost.ps1 ausfuehren und nach einer Rolleninstallation neu starten."
    }

    Import-Module Hyper-V -ErrorAction Stop

    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        throw "Hyper-V Cmdlets sind nicht verfuegbar. Bitte Server neu starten oder Hyper-V erneut aktivieren."
    }
}

$LogPath = Join-Path $DeployRoot "logs"
if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

Start-Transcript -Path "$LogPath\02-Create-InnerAutopilotVMs.log" -Force

$VMDefinitions = @(
    @{
        Name = "DC01"
        Iso = $ServerIso
        Memory = 4GB
        MinMemory = 2GB
        MaxMemory = 8GB
        Cpu = 2
        VhdSize = 100GB
        EnableTpm = $false
        Notes = "Domain Controller, DNS, DHCP und Intune Connector fuer Autopilot Hybrid Schulung."
    },
    @{
        Name = "WIN11-Normal"
        Iso = $Win11Iso
        Memory = 4GB
        MinMemory = 2GB
        MaxMemory = 8GB
        Cpu = 2
        VhdSize = 100GB
        EnableTpm = $true
        Notes = "Normales Windows 11 Vergleichsgeraet. Darf klassisch installiert werden."
    },
    @{
        Name = "WIN11-OOBE"
        Iso = $Win11Iso
        Memory = 4GB
        MinMemory = 2GB
        MaxMemory = 8GB
        Cpu = 2
        VhdSize = 100GB
        EnableTpm = $true
        Notes = "Autopilot-Testgeraet. Nur bis OOBE installieren. Nicht fertig einrichten."
    }
)

Write-Host ""
Write-Host "Erstelle innere Autopilot-Lab-VMs..." -ForegroundColor Cyan

Assert-HyperVReady

if (-not (Get-VMSwitch -Name $LabSwitchName -ErrorAction SilentlyContinue)) {
    throw "vSwitch $LabSwitchName wurde nicht gefunden. Bitte zuerst 01-Prepare-NestedHyperVHost.ps1 ausfuehren."
}

if (-not (Test-Path $ServerIso)) {
    throw "Windows Server ISO nicht gefunden: $ServerIso"
}

if (-not (Test-Path $Win11Iso)) {
    throw "Windows 11 ISO nicht gefunden: $Win11Iso"
}

foreach ($Folder in @($BasePath, $VMPath, $VHDXPath)) {
    if (-not (Test-Path $Folder)) {
        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    }
}

function New-AutopilotTrainingVM {
    param (
        [string]$Name,
        [string]$Iso,
        [int64]$Memory,
        [int64]$MinMemory,
        [int64]$MaxMemory,
        [int]$Cpu,
        [int64]$VhdSize,
        [bool]$EnableTpm,
        [string]$Notes
    )

    $ThisVMPath = Join-Path $VMPath $Name
    $ThisVHDPath = Join-Path $VHDXPath "$Name.vhdx"

    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
        Write-Host "VM existiert bereits, ueberspringe: $Name" -ForegroundColor Yellow
        return
    }

    if (-not (Test-Path $ThisVMPath)) {
        New-Item -ItemType Directory -Path $ThisVMPath -Force | Out-Null
    }

    Write-Host "Erstelle VM: $Name" -ForegroundColor Cyan

    New-VM -Name $Name -Generation 2 -MemoryStartupBytes $Memory -Path $ThisVMPath -NewVHDPath $ThisVHDPath -NewVHDSizeBytes $VhdSize -SwitchName $LabSwitchName | Out-Null

    Set-VMProcessor -VMName $Name -Count $Cpu
    Set-VMMemory -VMName $Name -DynamicMemoryEnabled $true -MinimumBytes $MinMemory -MaximumBytes $MaxMemory

    Add-VMDvdDrive -VMName $Name -Path $Iso
    $DvdDrive = Get-VMDvdDrive -VMName $Name

    Set-VMFirmware -VMName $Name -EnableSecureBoot On -SecureBootTemplate "MicrosoftWindows" -FirstBootDevice $DvdDrive

    if ($EnableTpm) {
        try {
            Set-VMKeyProtector -VMName $Name -NewLocalKeyProtector
            Enable-VMTPM -VMName $Name
            Write-Host "vTPM aktiviert fuer: $Name" -ForegroundColor Green
        } catch {
            Write-Host "Warnung: vTPM konnte fuer $Name nicht aktiviert werden: $_" -ForegroundColor Yellow
        }
    }

    Enable-VMIntegrationService -VMName $Name -Name "Gastdienstschnittstelle" -ErrorAction SilentlyContinue
    Enable-VMIntegrationService -VMName $Name -Name "Guest Service Interface" -ErrorAction SilentlyContinue

    Set-VM -Name $Name -Notes $Notes

    Write-Host "VM erstellt: $Name" -ForegroundColor Green
}

foreach ($VM in $VMDefinitions) {
    New-AutopilotTrainingVM -Name $VM.Name -Iso $VM.Iso -Memory $VM.Memory -MinMemory $VM.MinMemory -MaxMemory $VM.MaxMemory -Cpu $VM.Cpu -VhdSize $VM.VhdSize -EnableTpm $VM.EnableTpm -Notes $VM.Notes
}

Write-Host ""
Write-Host "Innere VMs wurden erstellt." -ForegroundColor Green
Write-Host ""
Write-Host "Installationsreihenfolge:"
Write-Host "1. DC01 installieren"
Write-Host "2. In DC01: 03-Setup-DC01-AutopilotHybrid.ps1 ausfuehren"
Write-Host "3. WIN11-Normal normal installieren"
Write-Host "4. WIN11-OOBE nur bis OOBE installieren und dort stoppen"
Write-Host ""
Write-Host "Wichtig: WIN11-OOBE nicht mit lokalem Benutzer fertig einrichten."

Stop-Transcript
