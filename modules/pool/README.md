# modules/pool

One **independent** storage pool. Each pool is meant to live in its **own state**
so it can be added, scaled, or destroyed without touching other pools or the
mgmt stack. Consumes the foundation from [`modules/network`](../network).

Creates, scoped to a single pool:

- two ENIs per node (primary on the mgmt subnet, secondary on the data subnet)
- one EC2 instance per node, round-robin across the network's AZs
- per-node EBS cache volumes + attachments (when `raid_level = 0`)
- a pool IAM role (S3 access, plus EBS-migrate when `raid_level = 0`) + instance profile
- the pool's S3 storage/backup buckets
- node provisioning via [`modules/provision`](../provision)
- an SSM parameter `/mgx/<cluster>/pools/<pool>` the mgmt stack discovers

## IP addressing

ENIs are created **without** `private_ips` — AWS assigns them and the ENI pins
the IP for life, so node identity (`uuid5` of the IP) is stable across instance
replacement. There is **no per-pool IP range to allocate**; addresses are
outputs, published to SSM for the mgmt stack. `ignore_changes = [private_ips]`
keeps drift from ever replacing an ENI.

## Usage

```hcl
data "terraform_remote_state" "network" { /* ... */ }

module "pool" {
  source = "migrx-io/mgx/aws//modules/pool"

  cluster   = "main"
  pool_name = "pool1"
  region    = "us-east-1"
  network   = data.terraform_remote_state.network.outputs

  nodes_ami           = "ami-029f1e8b2d0665554"
  nodes_instance_type = "m8gb.xlarge"
  nodes_count         = 3

  raid_level            = 0
  nvme_node_disks_count = 10            # must equal total ebs_volumes count
  max_volumes_count     = 10
  r_cache_size_in_mib   = 90000
  rw_cache_size_in_mib  = 10000
  ebs_volumes = [{ size = 100, type = "gp3", iops = 3000, throughput = 125, count = 10 }]

  s3_bucket_names        = ["mgxs3storage1"]
  s3_backup_bucket_names = ["mgxs3backup1"]
  s3_force_destroy       = true
  enable_metrics         = true

  scripts_path = "${path.module}/../../scripts"
  # secrets_file_path defaults to ./secrets.env (the dir terraform runs from)
}
```

A runnable root is in [`examples/pool`](../../examples/pool).

For `ssh` provisioning, `secrets_file_path` defaults to `secrets.env` in the
directory terraform runs from. It is shared by every node (mgmt + storage) and
git-ignored — create it from the template before applying:

```bash
cp ../../scripts/secrets.env.example secrets.env
```

Keys: `CASS_USER`, `CASS_PASSWD`, `MGX_GW_X_API_KEY`, `MGX_X_API_KEY`,
`MGX_GW_ADMIN_PASSWD` (see the [root README](../../README.md#setup) for
descriptions).

## Key inputs

| Name | Type | Description |
|------|------|-------------|
| `cluster` | `string` | SSM namespace the mgmt stack discovers pools from. |
| `pool_name` | `string` | Unique pool name (names, tags, SSM key). |
| `region` | `string` | Region (pool_info.json + EBS-migrate IAM scope). |
| `network` | `object` | Outputs from the network module. |
| `nodes_ami` / `nodes_instance_type` / `nodes_count` | | Node fleet. |
| `raid_level` | `number` | `0` = EBS RAID0 cache (single AZ); `1`/`10` = local NVMe. |
| `ebs_volumes` | `list(object)` | Per-node EBS cache volumes (raid_level 0). |
| `nvme_node_disks_count` / `max_volumes_count` | `number` | Cache/volume sizing. |
| `r_cache_size_in_mib` / `rw_cache_size_in_mib` | `number` | Per-disk cache sizes. |
| `s3_bucket_names` / `s3_backup_bucket_names` / `s3_bucket_access_names` | `list(string)` | Owned + shared buckets. |
| `enable_metrics` / `enable_grafana` | `bool` | Observability. |
| `provision_enabled` | `bool` | Toggle SSH provisioning (false = infra only). |
| `scripts_path` / `secrets_file_path` | `string` | Provisioning inputs. |
| `ssh_user` / `ssh_private_key_path` | `string` | SSH access via the bastion. |

## Outputs

`pool_name`, `node_mgmt_private_ips`, `node_data_private_ips`, `instance_ids`,
`iam_role_name`, `ssm_registry_parameter`, `s3_bucket_names`, `s3_backup_bucket_names`.

## Preconditions

- `raid_level = 0` requires a single-AZ network and `nvme_node_disks_count` equal
  to the total `ebs_volumes` count.
