# ============================================================
# 06-Join-WIN11-Normal-ToDomain.ps1
#
# Optional auf WIN11-Normal nach normaler Installation ausführen.
# ============================================================

param (
    [string]$DomainName = "training.local"
)

$Credential = Get-Credential -Message "Domänen-Admin angeben, z. B. TRAINING\Administrator"

Add-Computer -DomainName $DomainName -Credential $Credential -Restart
