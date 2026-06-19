# ============================================================
# 00-Prepare-AutopilotHV-Template.ps1
#
# Dieses Script wird IN der einmaligen Template-Build-VM ausgeführt.
#
# Ziel:
# - unattend.xml erzeugen
# - lokalen Admin per OOBE anlegen lassen
# - RDP/WinRM vorbereiten
# - optional Hyper-V Rolle installieren
# - optional Bootstrap-Link auf Desktop ablegen
# - Sysprep ausführen und VM herunterfahren
#
# Danach die VHDX als Template ablegen.
# ============================================================

param (
    [string]$LocalAdminUser = "LabAdmin",
    [string]$TimeZone = "W. Europe Standard Time",
    [string]$BootstrapRawUrl = "https://raw.githubusercontent.com/DEIN-ORG/AutopilotHybridLab/main/bootstrap/Install-AutopilotLabScripts.ps1",
    [switch]$InstallHyperVRole,
    [switch]$CreateDesktopBootstrapStarter,
    [switch]$RunSysprep
)

function ConvertTo-XmlEscaped {
    param ([string]$Text)
    return [System.Security.SecurityElement]::Escape($Text)
}

Write-Host ""
Write-Host "Autopilot-HV Template Vorbereitung" -ForegroundColor Cyan
Write-Host "Lokaler Admin: $LocalAdminUser"
Write-Host ""

$SecurePassword = Read-Host "Kennwort für $LocalAdminUser" -AsSecureString
$Bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
try {
    $PlainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto($Bstr)
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Bstr)
}

if ([string]::IsNullOrWhiteSpace($PlainPassword)) {
    throw "Kennwort darf nicht leer sein."
}

$EscapedPassword = ConvertTo-XmlEscaped -Text $PlainPassword
$EscapedUser = ConvertTo-XmlEscaped -Text $LocalAdminUser
$EscapedTimeZone = ConvertTo-XmlEscaped -Text $TimeZone

Write-Host "Aktiviere WinRM..." -ForegroundColor Cyan
Enable-PSRemoting -Force

Write-Host "Aktiviere RDP..." -ForegroundColor Cyan
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue

Set-ExecutionPolicy RemoteSigned -Force

New-Item -Path "HKLM:\SOFTWARE\Microsoft\ServerManager" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager" -Name "DoNotOpenServerManagerAtLogon" -Value 1 -Type DWord

New-Item -ItemType Directory -Path "C:\Deploy\bootstrap", "C:\Deploy\scripts", "C:\Deploy\logs", "C:\Deploy\temp" -Force | Out-Null

if ($CreateDesktopBootstrapStarter) {
    $StarterPath = "C:\Users\Public\Desktop\Autopilot-Lab installieren.ps1"
    $StarterContent = @"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "New-Item -ItemType Directory -Path 'C:\Deploy\bootstrap' -Force | Out-Null; iwr -UseBasicParsing '$BootstrapRawUrl' -OutFile 'C:\Deploy\bootstrap\Install-AutopilotLabScripts.ps1'; & 'C:\Deploy\bootstrap\Install-AutopilotLabScripts.ps1' -RunPrepareHost"
"@
    Set-Content -Path $StarterPath -Value $StarterContent -Encoding UTF8 -Force
    Write-Host "Desktop-Starter erstellt: $StarterPath" -ForegroundColor Green
}

if ($InstallHyperVRole) {
    Write-Host "Installiere Hyper-V Rolle in das Template..." -ForegroundColor Cyan
    Write-Host "Hinweis: Die Build-VM muss dafür Nested Virtualization unterstützen." -ForegroundColor Yellow
    Install-WindowsFeature -Name Hyper-V -IncludeManagementTools
}

$PantherPath = "C:\Windows\Panther"
$SetupScriptsPath = "C:\Windows\Setup\Scripts"

New-Item -ItemType Directory -Path $PantherPath -Force | Out-Null
New-Item -ItemType Directory -Path $SetupScriptsPath -Force | Out-Null

$UnattendPath = Join-Path $PantherPath "AutopilotHV-Unattend.xml"
$SetupCompletePath = Join-Path $SetupScriptsPath "SetupComplete.cmd"
$FirstBootScriptPath = Join-Path $SetupScriptsPath "FirstBoot-AutopilotHV.ps1"

$UnattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend"
          xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">

  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <ComputerName>*</ComputerName>
      <TimeZone>$EscapedTimeZone</TimeZone>
      <RegisteredOwner>MAHR EDV</RegisteredOwner>
      <RegisteredOrganization>MAHR EDV</RegisteredOrganization>
    </component>
  </settings>

  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <InputLocale>de-DE</InputLocale>
      <SystemLocale>de-DE</SystemLocale>
      <UILanguage>de-DE</UILanguage>
      <UserLocale>de-DE</UserLocale>
    </component>

    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">

      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>

      <TimeZone>$EscapedTimeZone</TimeZone>

      <UserAccounts>
        <AdministratorPassword>
          <Value>$EscapedPassword</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>

        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Password>
              <Value>$EscapedPassword</Value>
              <PlainText>true</PlainText>
            </Password>
            <Description>Lokaler Administrator für Autopilot-Hybrid-Schulungssysteme</Description>
            <DisplayName>$EscapedUser</DisplayName>
            <Group>Administrators</Group>
            <Name>$EscapedUser</Name>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>

    </component>
  </settings>

</unattend>
"@

Set-Content -Path $UnattendPath -Value $UnattendXml -Encoding UTF8 -Force
Write-Host "Unattend-Datei erstellt: $UnattendPath" -ForegroundColor Green

$FirstBootScript = @"
Start-Transcript -Path "C:\Deploy\logs\AutopilotHV-FirstBoot.log" -Force

Enable-PSRemoting -Force
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue

New-Item -Path "HKLM:\SOFTWARE\Microsoft\ServerManager" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager" -Name "DoNotOpenServerManagerAtLogon" -Value 1 -Type DWord

Remove-Item "C:\Windows\Panther\AutopilotHV-Unattend.xml" -Force -ErrorAction SilentlyContinue
Remove-Item "C:\Windows\Panther\Unattend.xml" -Force -ErrorAction SilentlyContinue
Remove-Item "C:\Windows\System32\Sysprep\Unattend.xml" -Force -ErrorAction SilentlyContinue

Stop-Transcript
"@

Set-Content -Path $FirstBootScriptPath -Value $FirstBootScript -Encoding UTF8 -Force

$SetupComplete = @"
@echo off
powershell.exe -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\FirstBoot-AutopilotHV.ps1
exit /b 0
"@

Set-Content -Path $SetupCompletePath -Value $SetupComplete -Encoding ASCII -Force
Write-Host "SetupComplete erstellt: $SetupCompletePath" -ForegroundColor Green

if ($RunSysprep) {
    Write-Host ""
    Write-Host "Starte Sysprep. Die VM wird danach heruntergefahren." -ForegroundColor Yellow

    $SysprepExe = "C:\Windows\System32\Sysprep\Sysprep.exe"

    if (-not (Test-Path $SysprepExe)) {
        throw "Sysprep nicht gefunden: $SysprepExe"
    }

    Start-Process -FilePath $SysprepExe -ArgumentList "/generalize /oobe /shutdown /unattend:$UnattendPath" -Wait
} else {
    Write-Host ""
    Write-Host "Vorbereitung abgeschlossen, Sysprep wurde noch NICHT ausgeführt." -ForegroundColor Yellow
    Write-Host "Zum Finalisieren ausführen:" -ForegroundColor Cyan
    Write-Host ".\00-Prepare-AutopilotHV-Template.ps1 -RunSysprep"
}
