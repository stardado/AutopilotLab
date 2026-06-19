# Autopilot Hybrid Lab Deployment

Dieses Repo enthält die Scripte für ein Autopilot-Hybrid-Schulungssystem auf eurer Hyper-V-/Cluster-Umgebung.

## Zielbild

Das äußere Deployment erstellt pro Teilnehmer oder Umgebung einen Nested-Hyper-V-Server:

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

## Aktuelle Standardpfade

```text
C:\Deploy\bootstrap
C:\Deploy\scripts
C:\Deploy\logs
C:\Deploy\temp
C:\Deploy\ISO
C:\AutopilotLab\VMs
C:\AutopilotLab\VHDX
```

Die ISO-Dateien werden hier erwartet:

```text
C:\Deploy\ISO\WindowsServer2022.iso
C:\Deploy\ISO\Win11.iso
```

## Schnellstart auf dem Nested-HV

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "New-Item -ItemType Directory -Path 'C:\Deploy\bootstrap' -Force | Out-Null; iwr -UseBasicParsing 'https://raw.githubusercontent.com/stardado/AutopilotLab/main/bootstrap/Install-AutopilotLabScripts.ps1' -OutFile 'C:\Deploy\bootstrap\Install-AutopilotLabScripts.ps1'; & 'C:\Deploy\bootstrap\Install-AutopilotLabScripts.ps1' -RunPrepareHost"
```

Wenn die Hyper-V-Rolle installiert wird und der Server neu startet, den gleichen Befehl danach erneut ausführen.

Danach die ISO-Dateien nach `C:\Deploy\ISO` kopieren und die inneren VMs erstellen:

```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\Deploy\scripts\02-Create-InnerAutopilotVMs.ps1
```

## Rollen der inneren VMs

- `DC01`: Domain Controller, DNS, DHCP und optional Intune Connector for Active Directory
- `WIN11-Normal`: normales Windows 11 Vergleichsgerät
- `WIN11-OOBE`: Autopilot-Hybrid-Testgerät

## Intune-Werte

```text
Domain name: training.local
OU: OU=Autopilot,OU=Devices,DC=training,DC=local
Computer name prefix: AP-
Group Tag: HYBRID-TRAINING
```

Ohne XGS/Firewall arbeitet das innere Lab mit internem Hyper-V-Switch und NAT. Dadurch können alle Schulungsumgebungen denselben internen Bereich `10.10.0.0/24` verwenden, ohne sich gegenseitig zu stören.
