# Plugins (mgmt node)

# wait while core up
echo "Waiting for Core to be ready on port ${MGX_PORT}..."
until nc -z ${CASS_RPC_ADDR} ${MGX_PORT}; do
    sleep 2
done

# install plugins
# The storage/cache/scheduler/snapshot plugins run in MGX_ROLE=mgmt (API only):
# they hold the intent records that mgx-plgn-mgmt federates to the pools.
# mgx-rclone is data-plane only (snapshot transfers run on the pools), so it is
# not installed here.
apt install -t migrx -y mgx-plgn-aaa
apt install -t migrx -y mgx-plgn-notif
apt install -t migrx -y mgx-plgn-services
apt install -t migrx -y mgx-plgn-cache
apt install -t migrx -y mgx-plgn-storage
apt install -t migrx -y mgx-plgn-snapshot
apt install -t migrx -y mgx-plgn-scheduler
apt install -t migrx -y mgx-plgn-mgmt
apt install -t migrx -y mgx-metrics
