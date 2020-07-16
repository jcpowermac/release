#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# TODO:
# Worse case scenario tear down
# Use govc to remove virtual machines if terraform fails

export HOME=/tmp
export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AWS_DEFAULT_REGION=us-east-1

cluster_name=$(<"${SHARED_DIR}"/clustername.txt)
installer_dir=/tmp/installer
tfvars_path=/var/run/secrets/ci.openshift.io/cluster-profile/secret.auto.tfvars
echo "$(date -u --rfc-3339=seconds) - Copying config from shared dir..."

mkdir -p "${installer_dir}/auth"
pushd ${installer_dir}

cp -t "${installer_dir}" \
    "${SHARED_DIR}/install-config.yaml" \
    "${SHARED_DIR}/metadata.json" \
    "${SHARED_DIR}/terraform.tfvars" \
    "${SHARED_DIR}/bootstrap.ign" \
    "${SHARED_DIR}/worker.ign" \
    "${SHARED_DIR}/master.ign"

cp -t "${installer_dir}/auth" \
    "${SHARED_DIR}/kubeadmin-password" \
    "${SHARED_DIR}/kubeconfig"

# Copy sample UPI files
cp -rt "${installer_dir}" \
    /var/lib/openshift-install/upi/"${CLUSTER_TYPE}"/*

# Copy secrets to terraform path
cp -t "${installer_dir}" \
    ${tfvars_path}

tar -xf "${SHARED_DIR}/terraform_state.tar.xz"

rm -rf .terraform || true
terraform init -input=false -no-color
# In some instances either the IPAM records or AWS DNS records
# are removed before teardown is executed causing terraform destroy
# to fail - this is causing resource leaks. Do not refresh the state.
terraform destroy -refresh=false -auto-approve -no-color &
wait "$!"


# after terraform has deleted the instances remove the ip addresses from IPAM
echo "$(date -u --rfc-3339=seconds) - Request IP addresses based on tag (cluster_name) ..."

ip_address_ids=$(curl -H "Authorization: Token ${ipam_token}" "http://${ipam_ip_address}:8080/api/ipam/ip-addresses/\?tag\=${cluster_name}" | jq -r '.results[].id')

echo "$(date -u --rfc-3339=seconds) - Deleting IP address..."
for id in ${ip_address_ids};
do
    curl \
        -H "Authorization: Token ${ipam_token}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json; indent=4" \
        --request DELETE \
        "http://${ipam_ip_address}:8080/api/ipam/ip-addresses/${id}/"
done

