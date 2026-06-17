# A single storage pool, as its own state.
# Copy this directory per pool (or change the values) — each pool is an
# independent apply/destroy and reads the foundation from the network stack.

terraform {
  required_version = ">= 1.4"

  # backend "s3" {
  #   bucket = "acme-tf-state"
  #   key    = "mgx/pools/pool1/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

provider "aws" {
  region = "us-east-1"
}

data "terraform_remote_state" "network" {
  backend = "local" # swap for the backend the network stack uses
  config = {
    path = "../network/terraform.tfstate"
  }
}

module "pool" {
  source = "../../modules/pool"

  cluster   = "main"
  pool_name = "pool1"
  region    = "us-east-1"
  network   = data.terraform_remote_state.network.outputs

  description         = "Test pool1"
  labels              = "name=pool-1,env=dev"
  nodes_ami           = "ami-029f1e8b2d0665554"
  nodes_instance_type = "m8gb.xlarge"
  nodes_count         = 3

  # EBS RAID0 cache: pin the pool to a single AZ (EBS volumes are AZ-bound).
  az                    = "us-east-1a"
  raid_level            = 0
  nvme_node_disks_count = 10 # = total ebs_volumes count when raid_level = 0
  max_volumes_count     = 10
  r_cache_size_in_mib   = 90000
  rw_cache_size_in_mib  = 10000
  ebs_volumes = [{
    size       = 100
    type       = "gp3"
    iops       = 3000
    throughput = 125
    count      = 10
  }]

  s3_bucket_names        = ["mgxs3storage1"]
  s3_backup_bucket_names = ["mgxs3backup1"]
  s3_bucket_access_names = []
  s3_force_destroy       = true

  enable_metrics = true
  enable_grafana = false

  # provisioning (ssh / bastion mode)
  scripts_path      = "${path.module}/../../scripts"
  secrets_file_path = "${path.module}/../../scripts/secrets.env"
}

output "node_mgmt_private_ips" { value = module.pool.node_mgmt_private_ips }
output "node_data_private_ips" { value = module.pool.node_data_private_ips }
