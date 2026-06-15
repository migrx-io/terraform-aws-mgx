region = "us-east-1"

vpc_id = "vpc-095dc0635c6244fe3"

azs = ["us-east-1a"]

mgmt_subnet_cidrs = [
  "172.31.96.0/20", # us-east-1a primary
]

storage_subnet_cidrs = [
  "172.31.144.0/20", # us-east-1a secondary
]

bastion = {
  enable        = true
  vpc_subnet    = "subnet-06b5191fc3bf0caff"
  ami           = "ami-029f1e8b2d0665554"
  instance_type = "t4g.micro"
  whitelist_ips = ["0.0.0.0/0"]
}

mgmt_pool = {
  nodes_ami           = "ami-029f1e8b2d0665554"
  nodes_instance_type = "t4g.xlarge"
  nodes_count         = 3
  enable_metrics      = true
}

#
# Cache sizing: r_cache_size_in_mib (read cache) and rw_cache_size_in_mib (write
# cache) are PER-DISK sizes. How they map to physical capacity depends on raid_level.
#
# NVMe cache (raid_level = 1 or 10):
#   Each NVMe disk is its own SPDK lvstore. Write data is REPLICATED across peers,
#   so per disk the cache plugin carves ONE read lvol (r_cache_size_in_mib) plus
#   ONE write lvol PER PEER (rw_cache_size_in_mib x number_of_peers). The peer
#   count equals nodes_count, so the write cache footprint on each disk is
#   rw_cache_size_in_mib * nodes_count -- it must be split across that many peers.
#   Size against a SINGLE NVMe disk:
#     available     = disk_GiB * 1024 * 0.93           # ~7% reserved for metadata
#     rw_cache_size = available * 0.05
#     r_cache_size  = available - rw_cache_size * nodes_count   # nodes_count = peers
#
# EBS cache (raid_level = 0):
#   All per-node EBS volumes (ebs_volumes) are striped into ONE mdadm RAID0 and
#   formatted as a single filesystem; the read and write caches SHARE it (the read
#   cache is a bind mount of an .rcache subdir), so the write cache is NOT
#   multiplied by nodes_count. nvme_node_disks_count must equal the total
#   ebs_volumes count. Size against a SINGLE EBS volume (read + write share it):
#     available = ebs_volume_GiB * 1024 * 0.93
#     rw_cache_size + r_cache_size <= available        # e.g. rw ~10%, r ~90%
#

storage_pools = {
  pool1 = {
    description            = "Test pool1"
    labels                 = "name=pool-1,env=dev"
    nodes_ami              = "ami-029f1e8b2d0665554"
    nodes_instance_type    = "m8gb.xlarge"
    nodes_count            = 3
    nvme_node_disks_count  = 10 # = sum of ebs_volumes count when raid_level = 0
    max_volumes_count      = 10
    r_cache_size_in_mib    = 90000 # read cache
    rw_cache_size_in_mib   = 10000 # write cache
    raid_level             = 0     # 0 = EBS RAID0 cache built from ebs_volumes
    s3_bucket_names        = ["mgxs3storage1", "mgxs3storage2"]
    s3_backup_bucket_names = ["mgxs3backup1", "mgxs3backup2"]
    s3_force_destroy       = true
    enable_metrics         = true
    # EBS volumes attached per node and striped into one RAID0 cache.
    ebs_volumes = [
      {
        size       = 100
        type       = "gp3"
        iops       = 3000
        throughput = 125
        count      = 10
      }
    ]
  }
  pool2 = {
    description            = "Test pool2"
    labels                 = "name=pool-2,env=dev"
    nodes_ami              = "ami-029f1e8b2d0665554"
    nodes_instance_type    = "m8gb.xlarge"
    nodes_count            = 3
    nvme_node_disks_count  = 10 # = sum of ebs_volumes count when raid_level = 0
    max_volumes_count      = 10
    r_cache_size_in_mib    = 90000 # read cache
    rw_cache_size_in_mib   = 10000 # write cache
    raid_level             = 0     # 0 = EBS RAID0 cache built from ebs_volumes
    s3_bucket_names        = ["mgxs3storage2", "mgxs3storage1"]
    s3_backup_bucket_names = ["mgxs3backup2", "mgxs3backup1"]
    s3_force_destroy       = true
    enable_metrics         = true
    # EBS volumes attached per node and striped into one RAID0 cache.
    ebs_volumes = [
      {
        size       = 100
        type       = "gp3"
        iops       = 3000
        throughput = 125
        count      = 10
      }
    ]
  }
}
