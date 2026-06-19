# Quickstart

## Auf dem Cluster/Management-Host

```powershell
.\scripts\00-Deploy-Outer-HV-Environments.ps1
```

Abfragen:

```text
VLAN ID: 450
Wie viele Schulungsumgebungen sollen erstellt werden? 1-7: 4
```

Ergebnis:

```text
V450 DEMO-AP-HV-01
V450 DEMO-AP-HV-02
V450 DEMO-AP-HV-03
V450 DEMO-AP-HV-04
```

## Auf jedem Nested-HV

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "New-Item -ItemType Directory -Path 'C:\Deploy\bootstrap' -Force | Out-Null; iwr -UseBasicParsing 'https://raw.githubusercontent.com/DEIN-ORG/AutopilotHybridLab/main/bootstrap/Install-AutopilotLabScripts.ps1' -OutFile 'C:\Deploy\bootstrap\Install-AutopilotLabScripts.ps1'; & 'C:\Deploy\bootstrap\Install-AutopilotLabScripts.ps1' -RunPrepareHost"
```

Danach ISOs nach `D:\ISO` kopieren und innere VMs erstellen:

```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\Deploy\scripts\02-Create-InnerAutopilotVMs.ps1
```
