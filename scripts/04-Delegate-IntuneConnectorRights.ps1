# ============================================================
# 04-Delegate-IntuneConnectorRights.ps1
#
# Delegiert Rechte für den Intune Connector / Offline Domain Join.
# Ausführen auf DC01 nach Installation des Intune Connectors.
# ============================================================

param (
    [string]$ConnectorComputerName = "DC01"
)

$ErrorActionPreference = "Stop"

$LogRoot = "C:\Deploy\logs"
if (-not (Test-Path $LogRoot)) {
    New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
}
Start-Transcript -Path "$LogRoot\04-Delegate-IntuneConnectorRights.log" -Force

Import-Module ActiveDirectory

$DomainDn = (Get-ADDomain).DistinguishedName
$TargetOu = "OU=Autopilot,OU=Devices,$DomainDn"

$ConnectorComputer = Get-ADComputer $ConnectorComputerName -ErrorAction Stop
$Identity = "$($ConnectorComputer.SamAccountName)"

Write-Host ""
Write-Host "Delegiere Rechte für Intune Connector..." -ForegroundColor Cyan
Write-Host "Connector-Computer: $Identity"
Write-Host "Ziel-OU: $TargetOu"
Write-Host ""

# Computerobjekte erstellen/löschen
dsacls $TargetOu /G "$Identity`:CCDC;computer"

# Lesen/Schreiben auf Computerobjekte
dsacls $TargetOu /G "$Identity`:LC;;computer"
dsacls $TargetOu /G "$Identity`:RC;;computer"
dsacls $TargetOu /G "$Identity`:WD;;computer"
dsacls $TargetOu /G "$Identity`:WP;;computer"
dsacls $TargetOu /G "$Identity`:RP;;computer"

# Passwort ändern/zurücksetzen für Computerobjekte
dsacls $TargetOu /G "$Identity`:CA;Reset Password;computer"
dsacls $TargetOu /G "$Identity`:CA;Change Password;computer"

Write-Host ""
Write-Host "Berechtigungen wurden gesetzt." -ForegroundColor Green
Write-Host "Diese OU im Intune Domain Join Profile verwenden:"
Write-Host $TargetOu

Stop-Transcript
