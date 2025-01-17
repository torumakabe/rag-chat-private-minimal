#!/usr/bin/env bash

set -o pipefail

if [ $# -eq 0 ]; then
  echo "Usage: $0 <resource_group>"
  exit 1
fi

zones=$(az network private-dns zone list --resource-group "$1" --query '[].name' -o tsv)

for zone in $zones; do
  az network private-dns record-set a list --resource-group "$1" --zone-name "$zone" --query '[].{IP: aRecords[0].ipv4Address, FQDN: fqdn}' -o tsv  | sed 's/privatelink\.//' | sed 's/vaultcore/vault/' | sed 's/\.$//'
done
