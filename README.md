# mgx-storage Terraform modules

Terraform modules to deploy an [mgx-storage](https://migrx.io) cluster on AWS.
The deployment is composed of three components, each applied as its own
Terraform state:

| Component | Module | Purpose |
|-----------|--------|---------|
| Foundation | [`modules/network`](modules/network/README.md) | Subnets, NAT gateway, security group, bastion, key pair |
| Storage pool | [`modules/pool`](modules/pool/README.md) | One storage pool: nodes, ENIs, EBS cache, IAM, S3 |
| Management | [`modules/mgmt`](modules/mgmt/README.md) | Management (API) nodes |

Node provisioning is handled by a shared module,
[`modules/provision`](modules/provision/README.md).

```
modules/
  network/     mgmt/     pool/     provision/
examples/
  network/     mgmt/     pool/        # runnable reference roots
scripts/                              # node bootstrap (setup-node.sh, helpers, manifests)
```

You deploy the foundation once, then one `pool` stack per storage pool, plus the
`mgmt` stack. Pools register their node addresses in SSM under
`/mgx/<cluster>/pools/`; the management stack reads that path to build its pool
registry and metrics federation.

## Requirements

- Terraform >= 1.4
- AWS credentials with permissions for EC2, IAM, VPC, S3, and SSM
- An existing VPC and a public subnet (for the NAT gateway and bastion)
- A remote state backend (e.g. S3) shared by all stacks, so the `pool` and
  `mgmt` stacks can read the `network` stack's outputs
- For `ssh` provisioning: an SSH key pair and a `secrets.env` file
  (see [`scripts/secrets.env.example`](scripts))

## Setup

The example roots under `examples/` read the foundation outputs through a
`local` backend. For real deployments, point every stack at a shared remote
backend (S3, etc.). Each example is configured by editing the values inline in
its `main.tf`.

### 1. Foundation

```bash
cd examples/network
# edit main.tf for your account: vpc_id, azs, subnet CIDRs, bastion, key_name
terraform init
terraform apply
```

### 2. Storage pools

Apply one stack per pool. Copy the example directory (or use workspaces / a
tfvars file per pool) and give each a unique `pool_name`:

```bash
cd examples/pool
# edit main.tf for your account: pool_name, region, nodes_ami, instance/disk sizing, S3 buckets
terraform init
terraform apply
```

Each pool is an independent state — applying or destroying one does not affect
the others.

### 3. Management

Apply after the pools so the management nodes discover them on first boot:

```bash
cd examples/mgmt
# edit main.tf for your account: region, nodes_ami, instance type/count
terraform init
terraform apply
```

## Configuration

Key inputs per module (full reference in each module's README):

**network** — `vpc_id`, `azs`, `mgmt_subnet_cidrs`, `storage_subnet_cidrs`,
`bastion`, `nat_public_subnet_id`, `key_name`.

**pool** — `pool_name`, `region`, `network`, `nodes_ami`, `nodes_instance_type`,
`nodes_count`, `raid_level`, `ebs_volumes`, `nvme_node_disks_count`,
`r_cache_size_in_mib`, `rw_cache_size_in_mib`, `max_volumes_count`,
`s3_bucket_names`, `s3_backup_bucket_names`, `s3_bucket_access_names`,
`enable_metrics`, `enable_grafana`.

**mgmt** — `region`, `network`, `nodes_ami`, `nodes_instance_type`,
`nodes_count`, `enable_metrics`, `enable_grafana`.

### Cache sizing

`r_cache_size_in_mib` (read) and `rw_cache_size_in_mib` (write) are **per-disk**
sizes; how they map to capacity depends on `raid_level`:

- **NVMe cache (`raid_level` = 1 or 10).** Each NVMe disk is its own lvstore.
  Write data is replicated across peers, so per disk the cache carves one read
  lvol plus one write lvol per peer (`rw_cache_size_in_mib × nodes_count`). Size
  against a single disk:

  ```
  available = disk_GiB * 1024 * 0.93                       # ~7% reserved for metadata
  rw_cache_size * nodes_count + r_cache_size <= available  # rw is replicated per peer
  ```

- **EBS cache (`raid_level` = 0).** All per-node `ebs_volumes` are striped into
  one RAID0 filesystem shared by the read and write caches. `nvme_node_disks_count`
  must equal the total `ebs_volumes` count, and the pool must use a single AZ.
  Size against a single EBS volume:

  ```
  available = ebs_volume_GiB * 1024 * 0.93
  rw_cache_size + r_cache_size <= available     # e.g. rw ~10%, r ~90%
  ```

## Provisioning modes

Set `provision_mode` on the `pool` and `mgmt` modules:

- **`ssh`** (default) — Terraform connects through the bastion, uploads the local
  `scripts/` directory and `secrets.env`, and runs `setup-node.sh`. Required
  inputs: `scripts_path`, `secrets_file_path`, `ssh_user`, `ssh_private_key_path`.
- **`ssm`** — agentless, no bastion. Nodes pull a scripts tarball from
  `scripts_url`, read `secrets.env` from an SSM SecureString (`secrets_ssm_path`),
  and run via SSM Run Command. The modules attach `AmazonSSMManagedInstanceCore`
  to the node role automatically. Required inputs: `scripts_url`,
  `secrets_ssm_path`.

## Operations

| Task | Action |
|------|--------|
| Add a pool | New pool stack, `terraform apply`. |
| Remove a pool | `terraform destroy` in that pool's stack, then re-apply `mgmt`. |
| Scale a pool | Change `nodes_count`, `terraform apply` that pool. |
| Scale management | Change `nodes_count`, `terraform apply` the `mgmt` stack. |
| Re-register pools | `terraform apply` the `mgmt` stack. |

## Node addressing

Node ENIs are assigned private IPs by AWS and keep them for the life of the ENI,
including across instance reboots, AMI changes, and instance-type changes
(`ignore_changes = [private_ips]`). IPs change only if an ENI itself is
recreated (pool teardown or subnet change). The addresses are exposed as module
outputs and published to SSM for the management stack.

## Accessing nodes

Get the bastion address and connect with SSH agent forwarding:

```bash
terraform -chdir=examples/network output bastion_public_ip
eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_rsa
ssh -A ubuntu@<bastion_public_ip>
ssh -A ubuntu@<node_private_ip>      # from the bastion
```

Forward Grafana (when enabled) through the bastion:

```bash
ssh -L 127.0.0.1:3000:<node_private_ip>:3000 ubuntu@<bastion_public_ip> -N
```
