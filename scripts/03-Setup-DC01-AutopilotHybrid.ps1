# ============================================================
# 03-Setup-DC01-AutopilotHybrid.ps1
#
# Richtet DC01 fuer das Autopilot-Hybrid-Lab ein.
#
# Kein NAT / kein 10.10.0.x mehr.
# Neues Schema pro VLAN:
#   VLAN 555 -> DC01 10.45.55.10, Gateway 10.45.55.254
#   VLAN 556 -> DC01 10.45.56.10, Gateway 10.45.56.254
#
# Beispiel:
#   powershell.exe -ExecutionPolicy Bypass -File C:\Deploy\scripts\03-Setup-DC01-AutopilotHybrid.ps1 -EnvironmentVLAN 555
# ============================================================

param (
    [string]$NewComputerName = "DC01",
    [string]$DomainName = "training.local",
    [string]$NetbiosName = "TRAINING",
    [int]$EnvironmentVLAN = 0,
    [string]$IPAddress = "",
    [int]$PrefixLength = 24,
    [string]$Gateway = "",
    [string]$DhcpScopeName = "Autopilot-Lab",
    [string]$DhcpStart = "",
    [string]$DhcpEnd = "",
    [string]$DhcpSubnet = "255.255.255.0",
    [string[]]$DnsForwarders = @("1.1.1.1", "8.8.8.8"),
    [string]$TrainingUser = "max.mustermann"
)

$ErrorActionPreference = "Stop"

function Convert-VlanToAddress {
    param ([int]$VLAN, [int]$HostOctet)
    $VlanText = $VLAN.ToString("000")
    $SecondOctet = "4$($VlanText.Substring(0,1))"
    $ThirdOctet = $VlanText.Substring(1,2)
    return "10.$SecondOctet.$ThirdOctet.$HostOctet"
}

function Resolve-NetworkDefaults {
    if ($EnvironmentVLAN -gt 0) {
        if ([string]::IsNullOrWhiteSpace($IPAddress)) { $script:IPAddress = Convert-VlanToAddress -VLAN $EnvironmentVLAN -HostOctet 10 }
        if ([string]::IsNullOrWhiteSpace($Gateway)) { $script:Gateway = Convert-VlanToAddress -VLAN $EnvironmentVLAN -HostOctet 254 }
        if ([string]::IsNullOrWhiteSpace($DhcpStart)) { $script:DhcpStart = Convert-VlanToAddress -VLAN $EnvironmentVLAN -HostOctet 100 }
        if ([string]::IsNullOrWhiteSpace($DhcpEnd)) { $script:DhcpEnd = Convert-VlanToAddress -VLAN $EnvironmentVLAN -HostOctet 200 }
    }

    if ([string]::IsNullOrWhiteSpace($IPAddress) -or [string]::IsNullOrWhiteSpace($Gateway) -or [string]::IsNullOrWhiteSpace($DhcpStart) -or [string]::IsNullOrWhiteSpace($DhcpEnd)) {
        throw "Netzwerkparameter fehlen. Bitte -EnvironmentVLAN 555 angeben oder -IPAddress, -Gateway, -DhcpStart und -DhcpEnd manuell setzen."
    }
}

function Get-PrimaryAdapter {
    $Adapter = Get-NetAdapter | Where-Object {
        $_.Status -eq "Up" -and $_.Name -notlike "vEthernet*"
    } | Sort-Object ifIndex | Select-Object -First 1

    if (-not $Adapter) {
        $Adapter = Get-NetAdapter | Where-Object Status -eq "Up" | Sort-Object ifIndex | Select-Object -First 1
    }

    if (-not $Adapter) { throw "Keine aktive Netzwerkkarte gefunden." }
    return $Adapter
}

function Set-DCNetwork {
    param ([string]$IPAddress, [int]$PrefixLength, [string]$Gateway)

    $Adapter = Get-PrimaryAdapter
    Write-Host "Setze Netzwerk auf Adapter: $($Adapter.Name)" -ForegroundColor Cyan

    Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne "127.0.0.1" } |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

    Get-NetRoute -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

    New-NetIPAddress -InterfaceIndex $Adapter.ifIndex -IPAddress $IPAddress -PrefixLength $PrefixLength -DefaultGateway $Gateway | Out-Null
    Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses "127.0.0.1"

    Write-Host "Netzwerk gesetzt: $IPAddress/$PrefixLength, Gateway $Gateway" -ForegroundColor Green
}

$LogRoot = "C:\Deploy\logs"
if (-not (Test-Path $LogRoot)) { New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null }
Start-Transcript -Path "$LogRoot\03-Setup-DC01-AutopilotHybrid.log" -Force

Resolve-NetworkDefaults

$OuDevices = "Devices"
$OuAutopilot = "Autopilot"
$OuUsers = "Users-Schulung"

Write-Host ""
Write-Host "Richte DC01 ein..." -ForegroundColor Cyan
Write-Host "VLAN: $EnvironmentVLAN"
Write-Host "IP: $IPAddress/$PrefixLength"
Write-Host "Gateway: $Gateway"
Write-Host "DHCP: $DhcpStart - $DhcpEnd"
Write-Host ""

if ($env:COMPUTERNAME -ne $NewComputerName) {
    Rename-Computer -NewName $NewComputerName -Force
    Write-Host "Computername wurde auf $NewComputerName gesetzt." -ForegroundColor Yellow
    Write-Host "Bitte Server neu starten und dieses Script danach erneut ausfuehren." -ForegroundColor Yellow
    Stop-Transcript
    exit
}

Set-DCNetwork -IPAddress $IPAddress -PrefixLength $PrefixLength -Gateway $Gateway

Install-WindowsFeature AD-Domain-Services, DNS, DHCP -IncludeManagementTools

$DomainExists = $false
try { $null = Get-ADDomain -ErrorAction Stop; $DomainExists = $true } catch { $DomainExists = $false }

if (-not $DomainExists) {
    Write-Host "Erstelle neue AD-Forest-Domaene: $DomainName" -ForegroundColor Cyan
    $SafeModePassword = Read-Host "DSRM-Kennwort fuer den neuen DC" -AsSecureString

    Install-ADDSForest -DomainName $DomainName -DomainNetbiosName $NetbiosName -SafeModeAdministratorPassword $SafeModePassword -InstallDNS -Force

    Write-Host "Domaene wird erstellt. Server startet automatisch neu." -ForegroundColor Yellow
    Stop-Transcript
    exit
}

Import-Module ActiveDirectory
Import-Module DnsServer -ErrorAction SilentlyContinue
Import-Module DhcpServer -ErrorAction SilentlyContinue

try {
    Set-DnsServerForwarder -IPAddress $DnsForwarders -UseRootHint $true -ErrorAction Stop
    Write-Host "DNS Forwarder gesetzt: $($DnsForwarders -join ', ')" -ForegroundColor Green
} catch {
    Write-Host "DNS Forwarder konnten nicht gesetzt werden: $_" -ForegroundColor Yellow
}

try {
    Add-DhcpServerInDC -DnsName "$NewComputerName.$DomainName" -IPAddress $IPAddress -ErrorAction SilentlyContinue
} catch {
    Write-Host "DHCP Autorisierung konnte nicht gesetzt werden oder existiert bereits: $_" -ForegroundColor Yellow
}

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

if (-not (Get-ADOrganizationalUnit -LDAPFilter "(ou=$OuDevices)" -SearchBase $DomainDn -ErrorAction SilentlyContinue)) { New-ADOrganizationalUnit -Name $OuDevices -Path $DomainDn }
if (-not (Get-ADOrganizationalUnit -LDAPFilter "(ou=$OuAutopilot)" -SearchBase $DevicesDn -ErrorAction SilentlyContinue)) { New-ADOrganizationalUnit -Name $OuAutopilot -Path $DevicesDn }
if (-not (Get-ADOrganizationalUnit -LDAPFilter "(ou=$OuUsers)" -SearchBase $DomainDn -ErrorAction SilentlyContinue)) { New-ADOrganizationalUnit -Name $OuUsers -Path $DomainDn }

Write-Host "OU-Struktur erstellt/geprueft." -ForegroundColor Green

if (-not (Get-ADUser -Filter "SamAccountName -eq '$TrainingUser'" -ErrorAction SilentlyContinue)) {
    $TrainingUserPassword = Read-Host "Kennwort fuer Testbenutzer $TrainingUser" -AsSecureString
    New-ADUser -Name "Max Mustermann" -GivenName "Max" -Surname "Mustermann" -SamAccountName $TrainingUser -UserPrincipalName "$TrainingUser@$DomainName" -Path $UsersDn -AccountPassword $TrainingUserPassword -Enabled $true -PasswordNeverExpires $true
    Write-Host "Testbenutzer erstellt: $TrainingUser" -ForegroundColor Green
} else {
    Write-Host "Testbenutzer existiert bereits: $TrainingUser" -ForegroundColor Green
}

$ImportPath = "C:\AutopilotImport"
if (-not (Test-Path $ImportPath)) { New-Item -ItemType Directory -Path $ImportPath -Force | Out-Null }

if (-not (Get-SmbShare -Name "AutopilotImport" -ErrorAction SilentlyContinue)) {
    New-SmbShare -Name "AutopilotImport" -Path $ImportPath -FullAccess "Domain Admins", "Administrators" | Out-Null
}

Write-Host ""
Write-Host "DC01 ist fertig eingerichtet." -ForegroundColor Green
Write-Host "Domaene: $DomainName"
Write-Host "DC-IP: $IPAddress"
Write-Host "Autopilot OU fuer Intune Domain Join Profile:"
Write-Host $AutopilotDn
Write-Host "DHCP: $DhcpStart - $DhcpEnd"
Write-Host "AutopilotImport: \\$IPAddress\AutopilotImport"
Write-Host ""
Write-Host "Naechster Schritt: Intune Connector for Active Directory auf DC01 installieren."
Write-Host "Danach 04-Delegate-IntuneConnectorRights.ps1 ausfuehren."

Stop-Transcript
