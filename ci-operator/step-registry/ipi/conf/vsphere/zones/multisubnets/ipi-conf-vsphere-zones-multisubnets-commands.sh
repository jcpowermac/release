#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
# shellcheck source=/dev/null
declare vsphere_datacenter
declare vsphere_url
declare vsphere_portgroup
declare vsphere_extra_portgroup_1
declare vsphere_extra_portgroup_2
# shellcheck source=/dev/null
source "${SHARED_DIR}/vsphere_context.sh"
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

unset SSL_CERT_FILE 
unset GOVC_TLS_CA_CERTS
declare -a vips
mapfile -t vips < "${SHARED_DIR}"/vips.txt

# if loadbalancer is UserManaged, it's mean using external LB,
# then keepalived and haproxy will not deployed, but coredns still keep
if [[ ${LB_TYPE} == "UserManaged" ]]; then
    APIVIPS_DEF="apiVIPs:
      - ${vips[0]}"
    INGRESSVIPS_DEF="ingressVIPs:
      - ${vips[1]}"
    LB_TYPE_DEF="loadBalancer:
      type: UserManaged"
else
    APIVIPS_DEF=""
    INGRESSVIPS_DEF=""
    LB_TYPE_DEF=""
fi

CONFIG="${SHARED_DIR}/install-config.yaml"
base_domain=$(<"${SHARED_DIR}"/basedomain.txt)
machine_cidr=$(<"${SHARED_DIR}"/machinecidr.txt)

if [[ -z "${vsphere_extra_portgroup_1}" ]] || [[ -z "${vsphere_extra_portgroup_2}" ]]; then
   echo "The required extra leases is 2 at leaset, exit"
   exit 1
fi	
cat >>"${CONFIG}" <<EOF
baseDomain: $base_domain
controlPlane:
  name: "master"
  replicas: 3
  platform:
    vsphere:
      zones:
       - "us-east-1"
       - "us-east-2"
       - "us-east-3"
compute:
- name: "worker"
  replicas: 3
  platform:
    vsphere:
      zones:
       - "us-west-1"
       - "us-east-2"
       - "us-east-3"
platform:
  vsphere:
    ${LB_TYPE_DEF}
    ${APIVIPS_DEF}
    ${INGRESSVIPS_DEF}
    vCenter: "${vsphere_url}"
    username: "${GOVC_USERNAME}"
    password: ${GOVC_PASSWORD}
    network: ${vsphere_portgroup}
    datacenter: "${vsphere_datacenter}"
    cluster: vcs-mdcnc-workload-1
    defaultDatastore: mdcnc-ds-shared
    failureDomains:
    - name: us-east-1
      region: us-east
      zone: us-east-1a
      topology:
        computeCluster: /${vsphere_datacenter}/host/vcs-mdcnc-workload-1
        networks:
        - ${vsphere_portgroup}
        datastore: mdcnc-ds-shared
    - name: us-east-2
      region: us-east
      zone: us-east-2a
      topology:
        computeCluster: /${vsphere_datacenter}/host/vcs-mdcnc-workload-2
        networks:
        - ${vsphere_extra_portgroup_1}
        datastore: mdcnc-ds-shared
    - name: us-east-3
      region: us-east
      zone: us-east-3a
      topology:
        computeCluster: /${vsphere_datacenter}/host/vcs-mdcnc-workload-3
        networks:
        - ${vsphere_extra_portgroup_2}
        datastore: mdcnc-ds-shared
    - name: us-west-1
      region: us-west
      zone: us-west-1a
      topology:
        datacenter: datacenter-2
        computeCluster: /datacenter-2/host/vcs-mdcnc-workload-4
        networks:
        - ${vsphere_portgroup}
        datastore: mdcnc-ds-shared

networking:
  machineNetwork:
  - cidr: "${machine_cidr}"
EOF

# TODO: Add this back in once we have an vsphere
# environment that will support topology storage

#ZONAL_SC="${SHARED_DIR}/manifest_zonal-sc.yaml"
#PROM_CONFIG="${SHARED_DIR}/manifest_cluster-monitoring-config.yaml"
#
#
#cat >> ${ZONAL_SC} << EOF
#apiVersion: storage.k8s.io/v1
#kind: StorageClass
#metadata:
#  name: sc-zone-us-east-1a
#allowedTopologies:
#- matchLabelExpressions:
#  - key: topology.kubernetes.io/zone
#    values:
#    - us-east-1a
#parameters:
#  diskformat: thin
#provisioner: kubernetes.io/vsphere-volume
#reclaimPolicy: Delete
#volumeBindingMode: WaitForFirstConsumer
#EOF
#
#cat >> ${PROM_CONFIG} << EOF
#apiVersion: v1
#kind: ConfigMap
#metadata:
#  name: cluster-monitoring-config
#  namespace: openshift-monitoring
#data:
#  config.yaml:
#    prometheusK8s:
#      volumeClaimTemplate:
#        spec:
#          storageClassName: sc-zone-us-east-1a
#EOF
