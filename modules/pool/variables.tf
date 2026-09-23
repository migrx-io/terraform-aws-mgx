variable "cluster" {
  description = "Logical cluster name. Used as the SSM namespace (/mgx/<cluster>/pools/...) the mgmt stack discovers pools from."
  type        = string
  default     = "main"
}

variable "pool_name" {
  description = "Unique name of this storage pool (used in resource names, tags, and the SSM registry key)."
  type        = string
}

variable "region" {
  description = "AWS region (written into pool_info.json and used to scope the EBS-migrate IAM policy)."
  type        = string
}

variable "network" {
  description = "Outputs from the network module (typically via terraform_remote_state)."
  type = object({
    azs                = list(string)
    mgmt_subnet_ids    = list(string)
    storage_subnet_ids = list(string)
    internal_sg_id     = string
    key_name           = string
    bastion_enabled    = bool
    bastion_public_ip  = string
  })
}

variable "az" {
  description = "Pin every node and EBS volume in this pool to a single AZ by name (e.g. 'us-east-1a'). Must be one of network.azs. Required for raid_level = 0 on a multi-AZ network, since EBS volumes are AZ-bound. When null, nodes round-robin across all network AZs."
  type        = string
  default     = null
}

# --- Pool sizing / nodes ------------------------------------------------------

variable "description" {
  description = "Human-readable pool description (surfaced to the mgmt registry)."
  type        = string
  default     = ""
}

variable "labels" {
  description = "Comma-separated key=value labels for the pool (e.g. 'name=pool-1,env=dev')."
  type        = string
  default     = ""
}

variable "nodes_ami" {
  description = "AMI for the storage nodes."
  type        = string
}

variable "nodes_instance_type" {
  description = "EC2 instance type for the storage nodes."
  type        = string
}

variable "nodes_count" {
  description = "Number of storage nodes in this pool."
  type        = number

  validation {
    condition     = var.nodes_count >= 1
    error_message = "nodes_count must be at least 1."
  }
}

# --- Cache / SPDK -------------------------------------------------------------

variable "nvme_node_disks_count" {
  description = "Cache disks per node (local NVMe disks, or total EBS volume count when raid_level = 0)."
  type        = number
}

variable "max_volumes_count" {
  description = "Maximum number of block volumes the pool exposes (drives NBDS_MAX)."
  type        = number
}

variable "r_cache_size_in_mib" {
  description = "Per-disk read cache size in MiB."
  type        = number
}

variable "rw_cache_size_in_mib" {
  description = "Per-disk write cache size in MiB."
  type        = number
}

variable "raid_level" {
  description = "0 = EBS RAID0 cache (uses ebs_volumes, single AZ); 1/10 = local NVMe cache."
  type        = number

  validation {
    condition     = contains([0, 1, 10], var.raid_level)
    error_message = "raid_level must be 0, 1, or 10."
  }
}

variable "ebs_volumes" {
  description = "EBS volumes attached per node and striped into one RAID0 cache. Only used when raid_level = 0."
  type = list(object({
    size       = number
    type       = string
    iops       = optional(number)
    throughput = optional(number)
    count      = number
  }))
  default = []
}

# --- write-back cache tuning --------------------------------------------------
# Rendered into /etc/mgx-spdk on every node of the pool, so they apply to every
# volume the pool serves. Changing one re-provisions the nodes; running volumes
# pick it up on their next start.

variable "cache_flush_threads" {
  description = "nbd cache filter: threads flushing dirty cache blocks to the backing store (--nbd-param=cache-flush-threads)."
  type        = number
  default     = 10
}

variable "cache_flush_interval" {
  description = "nbd cache filter: milliseconds between flush passes (--nbd-param=cache-flush-interval)."
  type        = number
  default     = 300
}

variable "cache_flush_blocks" {
  description = "nbd cache filter: dirty blocks a single flush pass submits per thread (--nbd-param=cache-flush-blocks)."
  type        = number
  default     = 5
}

variable "cache_flush_max_age" {
  description = "nbd cache filter: milliseconds a dirty block may sit unflushed before it is forced out (--nbd-param=cache-flush-max-age)."
  type        = number
  default     = 3000
}

variable "cache_fill_threshold" {
  description = "nbd cache filter: cache fill percentage above which reads stop being cached on read (--nbd-param=cache-fill-threshold)."
  type        = number
  default     = 100
}

variable "cache_write_throttle_ms" {
  description = "nbd cache filter: write throttle delay in milliseconds (--nbd-param=cache-write-throttle-ms)."
  type        = number
  default     = 50
}

variable "cache_high_threshold" {
  description = "nbd cache filter: cache fill percentage high watermark (reclaim starts) (--nbd-param=cache-high-threshold)."
  type        = number
  default     = 95
}

variable "cache_low_threshold" {
  description = "nbd cache filter: cache fill percentage low watermark (reclaim target) (--nbd-param=cache-low-threshold)."
  type        = number
  default     = 85
}

variable "cache_reclaim_scan_blocks" {
  description = "nbd cache filter: blocks scanned per reclaim scan (--nbd-param=cache-reclaim-scan-blocks)."
  type        = number
  default     = 12800
}

variable "cache_reclaim_scan_tries" {
  description = "nbd cache filter: reclaim scan tries (--nbd-param=cache-reclaim-scan-tries)."
  type        = number
  default     = 20
}

variable "cache_lru_percent" {
  description = "nbd cache filter: LRU percentage (--nbd-param=cache-lru-percent)."
  type        = number
  default     = 50
}

variable "cache_reclaim_high_count" {
  description = "nbd cache filter: reclaim high count (--nbd-param=cache-reclaim-high-count)."
  type        = number
  default     = 2
}

variable "cache_reclaim_max_count" {
  description = "nbd cache filter: reclaim max count (--nbd-param=cache-reclaim-max-count)."
  type        = number
  default     = 64
}

variable "cache_max_overflow_percent" {
  description = "nbd cache filter: maximum cache overflow percentage (--nbd-param=cache-max-overflow-percent)."
  type        = number
  default     = 5
}

variable "cache_readahead_trigger" {
  description = "nbd cache filter: readahead trigger (--nbd-param=cache-readahead-trigger)."
  type        = number
  default     = 3
}

variable "cache_readahead_blocks" {
  description = "nbd cache filter: readahead blocks (--nbd-param=cache-readahead-blocks)."
  type        = number
  default     = 32
}

variable "cache_readahead_batch" {
  description = "nbd cache filter: readahead batch (--nbd-param=cache-readahead-batch)."
  type        = number
  default     = 4
}

variable "cache_readahead_threads" {
  description = "nbd cache filter: readahead threads (--nbd-param=cache-readahead-threads)."
  type        = number
  default     = 8
}

variable "cache_sync_interval" {
  description = "nbd cache filter: cache sync interval in milliseconds (--nbd-param=cache-sync-interval)."
  type        = number
  default     = 300
}

variable "cache_persist_interval" {
  description = "nbd cache filter: cache persist interval in milliseconds (--nbd-param=cache-persist-interval)."
  type        = number
  default     = 1000
}

variable "block_cache_flush_threads" {
  description = "Block cache: flush thread pool size (--cacheFlushThreads)."
  type        = number
  default     = 30
}

variable "block_read_threads" {
  description = "Block cache: read thread pool size (--blockReadThreads)."
  type        = number
  default     = 32
}

variable "block_cache_size" {
  description = "Block cache: in-memory size in MiB (--blockCacheSize)."
  type        = number
  default     = 300
}

variable "block_cache_threads" {
  description = "Block cache: write-back thread pool size (--blockCacheThreads)."
  type        = number
  default     = 30
}

# --- storage / snapshot plugin tuning ------------------------------------------
# Rendered into the pool's storage / snapshot plugin configs (storage.yaml),
# applied when the pool cluster is formed.

variable "storage_s3purge" {
  description = "Storage plugin: on volume delete, also delete the volume objects from the S3 data bucket, \"yes\" or \"no\" (storage_s3purge)."
  type        = string
  default     = "yes"
}

variable "cache_r_cache_size" {
  description = "Storage plugin: read cache size (cache_r_cache_size)."
  type        = number
  default     = 4096
}

variable "cache_rw_cache_size" {
  description = "Storage plugin: read-write cache size (cache_rw_cache_size)."
  type        = number
  default     = 1024
}

variable "qos_rw_ios_per_sec" {
  description = "Storage plugin: default volume QoS, read+write IOPS limit."
  type        = number
  default     = 16000
}

variable "qos_rw_mbytes_per_sec" {
  description = "Storage plugin: default volume QoS, read+write MB/s limit."
  type        = number
  default     = 250
}

variable "qos_r_mbytes_per_sec" {
  description = "Storage plugin: default volume QoS, read MB/s limit."
  type        = number
  default     = 250
}

variable "qos_w_mbytes_per_sec" {
  description = "Storage plugin: default volume QoS, write MB/s limit."
  type        = number
  default     = 250
}

variable "snapshot_storage_class" {
  description = "Snapshot plugin: S3 storage class for snapshot objects (storage_class)."
  type        = string
  default     = "GLACIER_IR"
}

variable "snapshot_transfers" {
  description = "Snapshot plugin: parallel object transfers per snapshot (transfers)."
  type        = number
  default     = 100
}

variable "snapshot_checkers" {
  description = "Snapshot plugin: parallel object checkers per snapshot (checkers)."
  type        = number
  default     = 64
}

variable "snapshot_max_running" {
  description = "Snapshot plugin: maximum snapshots running at once (max_running)."
  type        = number
  default     = 5
}

variable "snapshot_max_increments" {
  description = "Snapshot plugin: maximum snapshot increments (max_increments)."
  type        = number
  default     = 10
}

# --- S3 -----------------------------------------------------------------------

variable "s3_bucket_names" {
  description = "S3 bucket names to create and use for block data."
  type        = list(string)
  default     = []
}

variable "s3_backup_bucket_names" {
  description = "S3 bucket names to create for snapshot backups. Falls back to the storage bucket when empty."
  type        = list(string)
  default     = []
}

variable "s3_bucket_access_names" {
  description = "Buckets this pool only needs IAM ACCESS to (created/owned by another pool). No bucket resource is created."
  type        = list(string)
  default     = []
}

variable "s3_force_destroy" {
  description = "Allow deleting S3 buckets even if they still contain objects."
  type        = bool
  default     = false
}

# --- Observability ------------------------------------------------------------

variable "enable_metrics" {
  description = "Run node_exporter/prometheus on the pool nodes."
  type        = bool
  default     = false
}

variable "enable_grafana" {
  description = "Run grafana (VIP service) for the pool."
  type        = bool
  default     = false
}

variable "cross_peer_scrape" {
  description = "Each pool node's prometheus scrapes every peer (full per-pool replica). True (the default) suits standalone pools and lets mgmt federate one node per pool. Set false when the pool is attached to mgmt so each node scrapes only itself and mgmt scrapes every node directly (no node-selection SPOF)."
  type        = bool
  default     = true
}

# --- Provisioning -------------------------------------------------------------

variable "provision_enabled" {
  description = "Run node provisioning. Set false to create infrastructure only."
  type        = bool
  default     = true
}

variable "provision_mode" {
  description = "Provisioning transport: 'ssh' (default, via the bastion) or 'ssm' (agentless, no bastion)."
  type        = string
  default     = "ssh"

  validation {
    condition     = contains(["ssh", "ssm"], var.provision_mode)
    error_message = "provision_mode must be 'ssh' or 'ssm'."
  }
}

variable "node_scripts_dir" {
  description = "Where the prebaked runtime scripts live inside nodes_ami. setup-node.sh is run from here. Must match node_scripts_dir in the image build."
  type        = string
  default     = "/opt/mgx/scripts"
}

variable "provision_dir" {
  description = "Writable dir on the node where per-node dynamic files (secrets.env, ip lists, pool_info.json) are staged and read via MGX_PROVISION_DIR."
  type        = string
  default     = "/tmp/mgx-provision"
}

variable "secrets_file_path" {
  description = "[ssh] Local path to the secrets.env uploaded to nodes. Defaults to secrets.env in the directory terraform runs from (the stack dir)."
  type        = string
  default     = "secrets.env"
}

variable "ssh_user" {
  description = "[ssh] SSH user on the nodes and bastion."
  type        = string
  default     = "ubuntu"
}

variable "ssh_private_key_path" {
  description = "[ssh] Path to the SSH private key used to reach nodes via the bastion."
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "secrets_ssm_path" {
  description = "[ssm] SSM SecureString parameter holding secrets.env content."
  type        = string
  default     = ""
}

variable "root_volume_size" {
  description = "Root EBS volume size (GiB) for storage nodes."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Additional tags merged onto every resource."
  type        = map(string)
  default     = {}
}
