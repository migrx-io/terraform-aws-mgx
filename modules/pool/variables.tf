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

variable "scripts_path" {
  description = "[ssh] Local path to the node bootstrap scripts directory."
  type        = string
  default     = ""
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

variable "scripts_url" {
  description = "[ssm] HTTPS URL of a gzipped tarball of the scripts directory, pulled on the node."
  type        = string
  default     = ""
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
