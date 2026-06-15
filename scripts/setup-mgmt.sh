#!/bin/bash
set -euo pipefail

source ../secrets.env

export DEBIAN_FRONTEND=noninteractive
MGX_VAR_DIR=/var/lib/migrx
PY=/opt/mgx-pyenv3/bin/python

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
echo "MGX_ROLE=mgmt" >> /etc/mgx-env

# 5. Expose envs
export $(xargs < /etc/mgx-env)

# 6. Install cassandra
export CASS_RPC_SEEDS=$($PY ./setup-helper.py mgx-cass-seeds)
export CASS_NODES_COUNT=$($PY ./setup-helper.py mgx-cass-nodes-count)
bash -e ./mgx-cassandra-install-deb.sh

# 7. Start services
#    No SPDK on mgmt nodes: there is no data plane, so the mgx-spdk* services,
#    nqn, mdadm and initramfs steps from setup-storage.sh are intentionally omitted.
mkhomedir_helper mgx-core
chown mgx-core:mgx-core /etc/mgx-env
chown mgx-core:mgx-core -R /etc/cassandra/

systemctl enable mgx-core
systemctl enable mgx-gateway-api
systemctl enable cron

systemctl restart mgx-core
systemctl restart mgx-gateway-api
systemctl restart cron

# 8. Install plugins (includes mgx-plgn-mgmt, excludes the data-plane mgx-rclone)
bash -e ./mgx-plugins-mgmt-deb.sh

# 9. Enable metrics
IS_METRICS=$($PY ./setup-helper.py is-metrics-enabled)
if [ "$IS_METRICS" = "True" ]; then
    # update peers to scrape

    IPS=$CASS_RPC_SEEDS

    for port in 9100 8082; do
        REPLACEMENT="targets: [$(echo $IPS | sed "s/,/:$port', '/g" | sed "s/^/'/;s/$/:$port'/")]"
        sed -i "s|targets: \['localhost:$port'\]|$REPLACEMENT|"  /opt/mgx-metrics/prometheus/prometheus.yml
    done

    # federate: pull all series from every storage pool's prometheus (/federate)
    $PY ./setup-helper.py prometheus-federate >> /opt/mgx-metrics/prometheus/prometheus.yml

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

# 10. Install manifest (mgmt behavior config + downstream pool registry)
$PY ./setup-helper.py mgx-mgmt-cluster

echo "Mgmt OK!"
