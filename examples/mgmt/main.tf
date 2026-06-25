# Management plane, as its own state. Apply after the network stack and the
# pools, so the mgmt nodes discover the pools from SSM on first provision.

terraform {
  required_version = ">= 1.4"

  # backend "s3" {
  #   bucket = "acme-tf-state"
  #   key    = "mgx/mgmt/terraform.tfstate"
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

module "mgmt" {
  source = "../../modules/mgmt"

  cluster = "main"
  region  = "us-east-1"
  network = data.terraform_remote_state.network.outputs

  nodes_ami           = "ami-029f1e8b2d0665554"
  nodes_instance_type = "t4g.xlarge"
  nodes_count         = 3
  enable_metrics      = true
  enable_grafana      = true

  # provisioning (ssh / bastion mode). nodes_ami must be a prebaked mgx AMI
  # (built by mgx-packer): provisioning runs the baked setup-node.sh in place.
  # secrets_file_path defaults to ./secrets.env (this dir). Create it first:
  #   cp ../../secrets.env.example secrets.env
}

output "node_private_ips" { value = module.mgmt.node_private_ips }
output "discovered_pools" { value = module.mgmt.discovered_pools }
