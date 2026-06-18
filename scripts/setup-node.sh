#!/bin/bash
set -euo pipefail

# One AMI, two roles. ROLE selects which services run; everything is installed
# on every node so the image is identical:
#   storage (default) -> full data plane (SPDK, rclone) enabled
#   mgmt              -> API-only: SPDK and rclone installed but disabled,
#                        MGX_ROLE=mgmt set, prometheus federation + mgmt manifest.
# Invoked from provision.tf as `setup-node.sh storage` / `setup-node.sh mgmt`.
ROLE=${1:-storage}

source ../secrets.env

export DEBIAN_FRONTEND=noninteractive
MGX_VAR_DIR=/var/lib/migrx
PY=/opt/mgx-pyenv3/bin/python
MDADM_CONF_FILE="/etc/mdadm/mdadm.conf"

# 0. Wait while NAT will be reachable
sleep 30

while true; do
  echo "Checking repo availability via NAT..."
  if curl -s -o /dev/null -w "%{http_code}" https://repo.migrx.io | grep -q "404"; then
    echo "Repo reachable, NAT is ready."
    break
  fi
  echo "Repo not reachable yet, retrying in 10s..."
  sleep 10
done

# 1. install mgx-core and etc
bash -e ./mgx-bootstrap-deb.sh

# 2. Generate mgx-id and mgx-hosts
#    mgmt nodes have a single network, so storage_data_ips.txt holds the mgmt
#    IPs (written by terraform); mgx-id / first-node detection work as on storage.
MGX_ID=$($PY ./setup-helper.py mgx-id)

echo "${MGX_ID}" > ${MGX_VAR_DIR}/mgx-id

# 3. Set all hosts for pool
$PY ./setup-helper.py mgx-hosts > ${MGX_VAR_DIR}/mgx-hosts

# 4. Set envs
$PY ./setup-helper.py mgx-env > /etc/mgx-env

# mgmt role: plugins run API-only (no SPDK / reconcile loops). The plugins
# become a metadata/intent store and the mgx-plgn-mgmt plugin federates that
# state to the downstream pools (placement + push/pull). See mgx-plgn-mgmt.
if [ "$ROLE" = "mgmt" ]; then
    echo "MGX_ROLE=mgmt" >> /etc/mgx-env

    # Request logging: append every successful create/update/resize/delete/clear
    # request to the requests_log table, scoped to the cache/storage/snapshot
    # plugins. mgmt replays these entries onto the downstream pools (see
    # mgx-plgn-mgmt).
    echo 'MGX_REQUESTS_LOG="y"' >> /etc/mgx-env
    echo 'MGX_REQUESTS_FILTER_PLUGIN="cache|storage|snapshot"' >> /etc/mgx-env
    echo 'MGX_REQUESTS_FILTER_OP="_add|_create|_update|_resize|_del|_clear"' >> /etc/mgx-env
fi

# 5. Expose envs
export $(xargs < /etc/mgx-env)

# 6. Install cassandra
export CASS_RPC_SEEDS=$($PY ./setup-helper.py mgx-cass-seeds)
export CASS_NODES_COUNT=$($PY ./setup-helper.py mgx-cass-nodes-count)
bash -e ./mgx-cassandra-install-deb.sh

# 8. Install spdk deps (installed on every role for a single AMI; the mgx-spdk*
#    services are disabled on mgmt below).
export NBDS_MAX=$($PY ./setup-helper.py mgx-storage-vol-count)
bash -e ./mgx-spdk-deb.sh
$PY ./setup-helper.py mgx-spdk > /etc/mgx-spdk
cp ./mgx-spdk-cache /etc/mgx-spdk-cache

# 9. Start services
mkhomedir_helper mgx-core
chown mgx-core:mgx-core /etc/mgx-env
chown mgx-core:mgx-core /etc/mgx-spdk
chown mgx-core:mgx-core /etc/mgx-spdk-cache
chown mgx-core:mgx-core -R /etc/cassandra/

# Select SPDK services depending on the pool cache setup:
#   ebs  -> mgx-spdk only          (mgx-spdk-cache stopped and disabled)
#   nvme -> mgx-spdk + mgx-spdk-cache (both running)
CACHE_TYPE=$($PY ./setup-helper.py cache-type)

systemctl enable mgx-core
systemctl enable mgx-gateway-api
systemctl enable cron

systemctl restart mgx-core
systemctl restart mgx-gateway-api
systemctl restart cron

# SPDK is the data plane: storage runs it, mgmt is API-only so both spdk
# services stay disabled. The mgx-plgn-* plugins additionally self-gate on
# MGX_ROLE (API-only, no reconcile loops) on mgmt.
if [ "$ROLE" = "mgmt" ]; then
    systemctl disable --now mgx-spdk mgx-spdk-cache || true
else
    systemctl enable mgx-spdk
    systemctl restart mgx-spdk

    if [ "$CACHE_TYPE" = "nvme" ]; then
        systemctl enable mgx-spdk-cache
        systemctl restart mgx-spdk-cache
    else
        systemctl disable mgx-spdk-cache
        systemctl stop mgx-spdk-cache
    fi
fi

# 10. Install plugins (superset: includes data-plane mgx-rclone and the mgmt
#     federation plugin mgx-plgn-mgmt; unused ones idle per role).
bash -e ./mgx-plugins-deb.sh

# rclone backs snapshot transfers (data plane). Storage runs it; on mgmt the
# transfers happen on the pools, so it is installed but disabled.
if [ "$ROLE" = "mgmt" ]; then
    systemctl disable --now rclone || true
else
    systemctl enable rclone
    systemctl restart rclone
fi

# Enable metrics
IS_METRICS=$($PY ./setup-helper.py is-metrics-enabled)
if [ "$IS_METRICS" = "True" ]; then
    # update peers to scrape

    IPS=$CASS_RPC_SEEDS

    for port in 9100 8082; do
        REPLACEMENT="targets: [$(echo $IPS | sed "s/,/:$port', '/g" | sed "s/^/'/;s/$/:$port'/")]"
        sed -i "s|targets: \['localhost:$port'\]|$REPLACEMENT|"  /opt/mgx-metrics/prometheus/prometheus.yml
    done

    # mgmt federates: pull all series from every storage pool's prometheus (/federate)
    if [ "$ROLE" = "mgmt" ]; then
        $PY ./setup-helper.py prometheus-federate >> /opt/mgx-metrics/prometheus/prometheus.yml
    fi

    # set grafana secrets
    sed -i "s/^admin_user = .*/admin_user = ${GRAFANA_USER}/" \
        /opt/mgx-metrics/grafana/conf/defaults.ini

    sed -i "s/^admin_password = .*/admin_password = ${GRAFANA_PASSWD}/" \
        /opt/mgx-metrics/grafana/conf/defaults.ini

    systemctl enable node_exporter
    systemctl enable prometheus
    systemctl restart node_exporter
    systemctl restart prometheus
else
    echo "Metrics are disabled"
fi


# 11. Set nqn
echo "nqn.2014-08.org.nvmexpress:uuid:${MGX_ID}" > /etc/nvme/hostnqn

# 12. Disable mdadn auto assemble
# Add AUTO -all if not already present
if ! grep -q "^AUTO -all" "$MDADM_CONF_FILE"; then
  echo "AUTO -all" >> "$MDADM_CONF_FILE"
  echo "'AUTO -all' to $MDADM_CONF_FILE"
else
  echo "'AUTO -all' already present in $MDADM_CONF_FILE"
fi

echo "Updating kernel module dependencies..."
depmod -a

# Regenerate initramfs
echo "Updating initramfs..."
update-initramfs -u -k all

# 13. Install manifest
#     storage: cache/pool + storage/scheduler/snapshot config
#     mgmt:    mgmt behavior config + downstream pool registry
if [ "$ROLE" = "mgmt" ]; then
    $PY ./setup-helper.py mgx-mgmt-cluster
else
    $PY ./setup-helper.py mgx-cluster
fi

echo "$ROLE OK!"
