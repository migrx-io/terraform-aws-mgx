# modules/network

Foundation / networking for an mgx-storage deployment. Apply this **once** per
environment; the mgmt and pool stacks consume its outputs (via
`terraform_remote_state`) and add no shared infrastructure of their own.

It creates, in an existing VPC:

- one **management** and one **storage (data)** subnet per AZ
- a single **NAT gateway** + private route table shared by both subnet tiers
- an **internal** security group for mgmt/storage node ENIs (intra-VPC open)
- an optional **bastion** host + its security group
- the **EC2 key pair** used across the deployment

This module is provider-agnostic: it declares `required_providers` but no
`provider` block. Pass the AWS provider from the calling root.

## Usage

```hcl
module "network" {
  source = "migrx-io/mgx/aws//modules/network" # or a local/git path

  name_prefix = "mgx-storage"
  azs         = ["us-east-1a", "us-east-1b", "us-east-1c"]
  vpc_id      = "vpc-0123456789abcdef0"

  mgmt_subnet_cidrs    = ["172.31.96.0/20", "172.31.97.0/20", "172.31.98.0/20"]
  storage_subnet_cidrs = ["172.31.99.0/20", "172.31.100.0/20", "172.31.101.0/20"]

  bastion = {
    enable        = true
    vpc_subnet    = "subnet-0123456789abcdef0"
    ami           = "ami-029f1e8b2d0665554"
    instance_type = "t4g.micro"
    whitelist_ips = ["203.0.113.0/24"]
  }
}
```

A runnable root is in [`examples/network`](../../examples/network).

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `name_prefix` | `string` | `"mgx-storage"` | Prefix for resource names / Name tag. Make unique per deployment in an account. |
| `azs` | `list(string)` | — | Availability zones; subnets are indexed in this order. |
| `vpc_id` | `string` | — | Existing VPC to build in. |
| `mgmt_subnet_cidrs` | `list(string)` | — | One CIDR per AZ for the management subnets. |
| `storage_subnet_cidrs` | `list(string)` | — | One CIDR per AZ for the storage subnets. |
| `bastion` | `object` | disabled | Bastion config; see variable for fields. |
| `ssh_public_key_path` | `string` | `"~/.ssh/id_rsa.pub"` | Public key registered as the EC2 key pair. |
| `key_name` | `string` | `"mgx-deployer-key"` | EC2 key pair name (unique per deployment). |
| `tags` | `map(string)` | `{}` | Extra tags merged onto every resource. |

## Outputs

| Name | Description |
|------|-------------|
| `azs` | AZs in subnet index order. |
| `mgmt_subnet_ids` / `storage_subnet_ids` | Subnet IDs per AZ. |
| `mgmt_subnet_cidrs` / `storage_subnet_cidrs` | Subnet CIDRs per AZ. |
| `internal_sg_id` | SG for mgmt/storage node ENIs. |
| `key_name` | EC2 key pair name. |
| `bastion_enabled` | Whether a bastion was created. |
| `bastion_public_ip` / `bastion_private_ip` | Bastion addresses, or `""` when disabled. |

## Notes

- The NAT gateway is placed in `bastion.vpc_subnet`, which must be a **public**
  subnet with an internet gateway route. (This matches the original layout;
  a dedicated `nat_subnet` input can be added if you want to decouple them.)
- IP addressing for nodes is **not** managed here. ENIs in the pool/mgmt modules
  are auto-assigned IPs by AWS and pinned for life by the ENI resource, so no
  per-pool IP range needs to be allocated.
