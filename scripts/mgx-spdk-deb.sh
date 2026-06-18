# SPDK package install only. No env vars required, so this can be run standalone
# to bake an image. The runtime config (nbd module + per-node nbds_max, hugepages,
# cache dirs) lives in mgx-spdk-configure-deb.sh and must run on the actual setup.

# Deps for spdk
apt-get install -y linux-modules-extra-$(uname -r)
apt-get install -y libmlx5-1
apt-get install -y libnuma1
apt-get install -y librdmacm1
apt-get install -y libfuse3-3
apt-get install -y libpmem1
apt-get install -y libaio-dev
apt-get install -y libiscsi7
apt-get install -y nvme-cli

# Deps for top cmd 
apt-get install -y libncurses5-dev libncursesw5-dev

# Deps for s3Backer
apt-get install -y libfuse2 nbd-client

# install s3backer
apt-get install -t migrx -y mgx-s3backer

# install spdk
apt-get install -t migrx -y mgx-spdk

echo "SPDK packages installed. Run mgx-spdk-configure-deb.sh to configure the node."
