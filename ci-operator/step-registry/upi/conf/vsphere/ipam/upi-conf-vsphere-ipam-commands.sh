#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

function allocate_ip() {
    args=$(jq -c -n \
        --arg fqdn "$1" \
        --arg tag "$cluster_name" \
        '{dns_name: $fqdn,tags: [$tag]}')

    results=$(curl \
        -H "Authorization: Token ${ipam_token}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json; indent=4" \
        --request POST \
        --data "${args}" \
        "http://${ipam_ip_address}:8080/api/ipam/prefixes/${prefix_id}/available-ips/")

    ipaddr=$(echo ${results} | jq -r '.address')
}

HOME=/tmp
export HOME

cluster_name="${NAMESPACE}-${JOB_NAME_HASH}"
base_domain="origin-ci-int-aws.dev.rhcloud.com"
cluster_domain="${cluster_name}.${base_domain}"
ipam_json_filename=ipam.auto.tfvars.json

# Generate empty JSON strings

compute=$(jq -c -n '{compute_ips:[],compute_ip_addresses:[]}')
bootstrap=$(jq -c -n '{bootstrap_ip:"",bootstrap_ip_address:""}')
control_plane=$(jq -c -n '{control_plane_ips:[],control_plane_ip_addresses:[]}')
lb=$(jq -c -n '{lb_ip_address:""}')


echo "$(date -u --rfc-3339=seconds) - Allocating bootstrap ip address..."
allocate_ip "bootstrap-0.${cluster_name}.${base_domain_name}"
bootstrap=$(echo $bootstrap | jq -c --arg ip $ipaddr '.bootstrap_ip_address = $ip')
bootstrap=$(echo $bootstrap | jq -c --arg ip $ipaddr '.bootstrap_ip = $ip')

echo "$(date -u --rfc-3339=seconds) - Allocating lb ip address..."
allocate_ip "lb-0.${cluster_name}.${base_domain_name}"
lb=$(echo $lb | jq -c --arg ip $ipaddr '.lb_ip_address = $ip')

echo "$(date -u --rfc-3339=seconds) - Allocating compute ip address..."
for i in $(seq 0 2)
do
    allocate_ip "compute-${i}.${cluster_name}.${base_domain_name}"

    compute=$(echo $compute | jq -c --arg ip $ipaddr '.compute_ips += [$ip]')
    compute=$(echo $compute | jq -c --arg ip $ipaddr '.compute_ip_addresses += [$ip]')

done

echo "$(date -u --rfc-3339=seconds) - Allocating control-plane ip address..."
for i in $(seq 0 2)
do
    allocate_ip "control-plane-${i}.${cluster_name}.${base_domain_name}"

    control_plane=$(echo $control_plane | jq -c --arg ip $ipaddr '.control_plane_ips += [$ip]')
    control_plane=$(echo $control_plane | jq -c --arg ip $ipaddr '.control_plane_ip_addresses += [$ip]')

done

echo "$(date -u --rfc-3339=seconds) - Generating JSON tfvars ..."
echo "${compute} ${control_plane} ${bootstrap} ${lb} " | jq -s add > "${SHARED_DIR}/${ipam_json_filename}"

