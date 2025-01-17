param (
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroup
)

$zones = az network private-dns zone list --resource-group $ResourceGroup --query '[].name' -o tsv

foreach ($zone in $zones) {
    az network private-dns record-set a list --resource-group $ResourceGroup --zone-name $zone --query '[].{IP: aRecords[0].ipv4Address, FQDN: fqdn}' -o tsv |
    ForEach-Object { $_ -replace 'privatelink\.', '' -replace 'vaultcore', 'vault' -replace '\.$', '' }
}
