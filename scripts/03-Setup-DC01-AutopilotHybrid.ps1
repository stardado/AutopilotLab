# ============================================================
# 03-Setup-DC01-AutopilotHybrid.ps1
#
# Richtet DC01 für das Autopilot-Hybrid-Lab ein.
# ============================================================

param (
    [string]$NewComputerName = "DC01",
    [string]$DomainName = "training.local",
    [string]$NetbiosName = "TRAINING",
    [string]$IPAddress = "10.10.0.10",
    [int]$PrefixLength = 24,
    [string]$Gateway = "10.10.0.1",
    [string]$DhcpScopeName = "Autopilot-Lab",
    [string]$DhcpStart = "10.10.0.100",
    [string]$DhcpEnd = "10.10.0.200",
    [string]$DhcpSubnet = "255.255.255.0",
    [string]$SafeModePasswordPlain = "P@ssw0rd-Training-DC!",
    [string]$TrainingUser = "max.mustermann",
    [string]$TrainingUserPasswordPlain = "P@ssw0rd-Schulung-01!"
)

$ErrorActionPreference = "Stop"

$LogRoot = "C:\Deploy\logs"
if (-not (Test-Path $LogRoot)) {
    New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
}
Start-Transcript -Path "$LogRoot\03-Setup-DC01-AutopilotHybrid.log" -Force

$SafeModePassword = ConvertTo-SecureString $SafeModePasswordPlain -AsPlainText -Force
$TrainingUserPassword = ConvertTo-SecureString $TrainingUserPasswordPlain -AsPlainText -Force

$OuDevices = "Devices"
$OuAutopilot = "Autopilot"
$OuUsers = "Users-Schulung"

Write-Host ""
Write-Host "Richte DC01 ein..." -ForegroundColor Cyan

if ($env:COMPUTERNAME -ne $NewComputerName) {
    Rename-Computer -NewName $NewComputerName -Force
    Write-Host "Computername wurde auf $NewComputerName gesetzt." -ForegroundColor Yellow
    Write-Host "Bitte Server neu starten und dieses Script danach erneut ausführen." -ForegroundColor Yellow
    Stop-Transcript
    exit
}

$Adapter = Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1
if (-not $Adapter) { throw "Keine aktive Netzwerkkarte gefunden." }

Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -ne "127.0.0.1" } |
    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

New-NetIPAddress -InterfaceIndex $Adapter.ifIndex -IPAddress $IPAddress -PrefixLength $PrefixLength -DefaultGateway $Gateway -ErrorAction SilentlyContinue | Out-Null
Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses "127.0.0.1"

Write-Host "Netzwerk gesetzt: $IPAddress/$PrefixLength, Gateway $Gateway" -ForegroundColor Green

Install-WindowsFeature AD-Domain-Services, DNS, DHCP -IncludeManagementTools

$DomainExists = $false
try {
    $null = Get-ADDomain -ErrorAction Stop
    $DomainExists = $true
} catch {
    $DomainExists = $false
}

if (-not $DomainExists) {
    Write-Host "Erstelle neue AD-Forest-Domäne: $DomainName" -ForegroundColor Cyan

    Install-ADDSForest -DomainName $DomainName -DomainNetbiosName $NetbiosName -SafeModeAdministratorPassword $SafeModePassword -InstallDNS -Force

    Write-Host "Domäne wird erstellt. Server startet automatisch neu." -ForegroundColor Yellow
    Stop-Transcript
    exit
}

Import-Module ActiveDirectory

try {
    Set-DnsServerForwarder -IPAddress "1.1.1.1", "8.8.8.8" -UseRootHint $true -ErrorAction Stop
    Write-Host "DNS Forwarder gesetzt." -ForegroundColor Green
} catch {
    Write-Host "DNS Forwarder konnten nicht gesetzt werden: $_" -ForegroundColor Yellow
}

Add-DhcpServerInDC -DnsName "$NewComputerName.$DomainName" -IPAddress $IPAddress -ErrorAction SilentlyContinue

$ScopeId = ($IPAddress -replace "\.\d+$", ".0")

$ExistingScope = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Where-Object { $_.ScopeId -eq $ScopeId }

if (-not $ExistingScope) {
    Add-DhcpServerv4Scope -Name $DhcpScopeName -StartRange $DhcpStart -EndRange $DhcpEnd -SubnetMask $DhcpSubnet -State Active
    Set-DhcpServerv4OptionValue -ScopeId $ScopeId -Router $Gateway -DnsServer $IPAddress -DnsDomain $DomainName
    Write-Host "DHCP Scope erstellt: $DhcpStart - $DhcpEnd" -ForegroundColor Green
} else {
    Write-Host "DHCP Scope existiert bereits: $ScopeId" -ForegroundColor Green
}

$DomainDn = (Get-ADDomain).DistinguishedName

$DevicesDn = "OU=$OuDevices,$DomainDn"
$AutopilotDn = "OU=$OuAutopilot,$DevicesDn"
$UsersDn = "OU=$OuUsers,$DomainDn"

if (-not (Get-ADOrganizationalUnit -LDAPFilter "(ou=$OuDevices)" -SearchBase $DomainDn -ErrorAction SilentlyContinue)) {
    New-ADOrganizationalUnit -Name $OuDevices -Path $DomainDn
}

if (-not (Get-ADOrganizationalUnit -LDAPFilter "(ou=$OuAutopilot)" -SearchBase $DevicesDn -ErrorAction SilentlyContinue)) {
    New-ADOrganizationalUnit -Name $OuAutopilot -Path $DevicesDn
}

if (-not (Get-ADOrganizationalUnit -LDAPFilter "(ou=$OuUsers)" -SearchBase $DomainDn -ErrorAction SilentlyContinue)) {
    New-ADOrganizationalUnit -Name $OuUsers -Path $DomainDn
}

Write-Host "OU-Struktur erstellt/geprüft." -ForegroundColor Green

if (-not (Get-ADUser -Filter "SamAccountName -eq '$TrainingUser'" -ErrorAction SilentlyContinue)) {
    New-ADUser -Name "Max Mustermann" -GivenName "Max" -Surname "Mustermann" -SamAccountName $TrainingUser -UserPrincipalName "$TrainingUser@$DomainName" -Path $UsersDn -AccountPassword $TrainingUserPassword -Enabled $true -PasswordNeverExpires $true
    Write-Host "Testbenutzer erstellt: $TrainingUser" -ForegroundColor Green
} else {
    Write-Host "Testbenutzer existiert bereits: $TrainingUser" -ForegroundColor Green
}

$ImportPath = "C:\AutopilotImport"
if (-not (Test-Path $ImportPath)) {
    New-Item -ItemType Directory -Path $ImportPath -Force | Out-Null
}

if (-not (Get-SmbShare -Name "AutopilotImport" -ErrorAction SilentlyContinue)) {
    New-SmbShare -Name "AutopilotImport" -Path $ImportPath -FullAccess "Domain Admins", "Administrators" | Out-Null
}

Write-Host ""
Write-Host "DC01 ist fertig eingerichtet." -ForegroundColor Green
Write-Host ""
Write-Host "Domäne: $DomainName"
Write-Host "Autopilot OU für Intune Domain Join Profile:"
Write-Host $AutopilotDn
Write-Host ""
Write-Host "DHCP: $DhcpStart - $DhcpEnd"
Write-Host ""
Write-Host "Nächster Schritt: Intune Connector for Active Directory auf DC01 installieren."
Write-Host "Danach 04-Delegate-IntuneConnectorRights.ps1 ausführen."

Stop-Transcript
