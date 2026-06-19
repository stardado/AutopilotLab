# Autopilot Hybrid Lab Deployment

Dieses Paket enthält die Scripte für ein Autopilot-Hybrid-Schulungssystem auf eurer Hyper-V-/Cluster-Umgebung.

## Zielbild

Äußeres Cluster-Deployment erstellt pro Teilnehmer/Umgebung einen Nested-Hyper-V-Server:

```text
V<VLAN> DEMO-AP-HV-01
V<VLAN> DEMO-AP-HV-02
...
```

Auf jedem Nested-Hyper-V werden danach diese VMs erstellt:

```text
DC01
WIN11-Normal
WIN11-OOBE
```

- `DC01`: Domain Controller, DNS, DHCP, optional Intune Connector for Active Directory
- `WIN11-Normal`: normales Windows 11 Vergleichsgerät
- `WIN11-OOBE`: Autopilot-Hybrid-Testgerät, bleibt bis zur OOBE stehen

## Empfohlener Ablauf

### 1. Eigene HV-Template-VHDX vorbereiten

In einer einmaligen Template-Build-VM ausführen:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\00-Prepare-AutopilotHV-Template.ps1 -RunSysprep
```

Danach die generalisierte VHDX ablegen unter:

```text
C:\ClusterStorage\SAN02-VOL01-10K\Vorlagen\Autopilot-HV\Autopilot-HV-Server2022-Template.vhdx
```

### 2. Äußere Nested-HV-Umgebungen auf dem Cluster erstellen

Auf dem Management-Host/Cluster-Kontext ausführen:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\00-Deploy-Outer-HV-Environments.ps1
```

Das Script fragt ab:

- VLAN ID
- Anzahl Schulungsumgebungen, 1 bis 7

### 3. Bootstrap auf jedem Nested-HV aus Git laden

Einzeiler, Beispiel für GitHub Raw:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "New-Item -ItemType Directory -Path 'C:\Deploy\bootstrap' -Force | Out-Null; iwr -UseBasicParsing 'https://raw.githubusercontent.com/DEIN-ORG/AutopilotHybridLab/main/bootstrap/Install-AutopilotLabScripts.ps1' -OutFile 'C:\Deploy\bootstrap\Install-AutopilotLabScripts.ps1'; & 'C:\Deploy\bootstrap\Install-AutopilotLabScripts.ps1' -RunPrepareHost"
```

Der Bootstrap lädt alles nach:

```text
C:\Deploy\
├── bootstrap\
├── scripts\
├── logs\
└── temp\
```

### 4. ISOs ablegen

Auf dem Nested-HV:

```text
D:\ISO\WindowsServer2022.iso
D:\ISO\Win11.iso
```

### 5. Innere VMs erstellen

```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\Deploy\scripts\02-Create-InnerAutopilotVMs.ps1
```

### 6. DC01 einrichten

In der VM `DC01`:

```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\Deploy\scripts\03-Setup-DC01-AutopilotHybrid.ps1
```

### 7. Intune Connector installieren

Auf `DC01` den aktuellen **Intune Connector for Active Directory** installieren und anmelden.

Danach:

```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\Deploy\scripts\04-Delegate-IntuneConnectorRights.ps1
```

### 8. WIN11-OOBE vorbereiten

`WIN11-OOBE` nur bis zum OOBE-Screen starten. Dann:

```text
SHIFT + F10
powershell
```

Dann Script ausführen bzw. Inhalt einfügen:

```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\Deploy\scripts\05-Get-AutopilotHash-OOBE.ps1
```

## Intune-Werte

Domain Join Profile:

```text
Domain name:
training.local

OU:
OU=Autopilot,OU=Devices,DC=training,DC=local

Computer name prefix:
AP-
```

Autopilot Group Tag:

```text
HYBRID-TRAINING
```

## Hinweis

Ohne XGS/Firewall arbeitet das innere Lab mit internem Hyper-V-Switch und NAT. Dadurch können alle Schulungsumgebungen denselben internen Bereich `10.10.0.0/24` verwenden, ohne sich gegenseitig zu stören.
