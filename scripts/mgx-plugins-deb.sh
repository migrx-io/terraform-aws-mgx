# Plugins

# wait while core up
echo "Waiting for Core to be ready on port ${MGX_PORT}..."
until nc -z ${CASS_RPC_ADDR} ${MGX_PORT}; do
    sleep 2
done

# install plugins (superset for the single AMI)
# mgx-rclone is data-plane (snapshot transfers) and runs on storage nodes;
# mgx-plgn-mgmt federates intent to downstream pools and runs on mgmt nodes.
# Both are installed everywhere; setup-node.sh gates the corresponding services
# by role.
apt install -t migrx -y mgx-plgn-aaa
apt install -t migrx -y mgx-plgn-notif
apt install -t migrx -y mgx-plgn-services
apt install -t migrx -y mgx-plgn-cache
apt install -t migrx -y mgx-plgn-storage
apt install -t migrx -y mgx-plgn-snapshot
apt install -t migrx -y mgx-rclone
apt install -t migrx -y mgx-plgn-scheduler
apt install -t migrx -y mgx-plgn-mgmt
apt install -t migrx -y mgx-metrics
