# modules/mgmt

The management plane: a small pool of mgmt (API-only) nodes that federate state
to the downstream storage pools. Consumes the foundation from
[`modules/network`](../network) and is normally its own state.

Creates:

- one ENI + EC2 instance per mgmt node (single mgmt-subnet interface, no IAM profile)
- node provisioning via [`modules/provision`](../provision) with `role = mgmt`

## Pool discovery

The mgmt nodes need each storage pool's node IPs (for the pool registry and
Prometheus federation). This module **discovers** them at plan time from SSM:

```
data "aws_ssm_parameters_by_path" "/mgx/<cluster>/pools/"
```

Each pool stack publishes `/mgx/<cluster>/pools/<pool> = {node_ips, descr, labels}`
(see [`modules/pool`](../pool)). The mgmt provisioner renders these into
`pool_info.json` in exactly the shape `setup-helper.py` already expects, so the
node scripts are unchanged.

This decouples the states: adding or removing a pool never requires editing the
mgmt configuration.

> **Re-register on pool changes.** When the discovered pool set changes, the
> `pool_info.json` hash changes and the mgmt nodes re-provision (re-running
> `setup-node.sh mgmt`, which re-applies the mgmt manifest). It is correct but
> heavier than a pure re-register; a lighter dedicated re-register hook is a
> future improvement. Run `terraform apply` on the mgmt stack after adding pools.

## Usage

```hcl
data "terraform_remote_state" "network" { /* ... */ }

module "mgmt" {
  source = "migrx-io/mgx/aws//modules/mgmt"

  cluster = "main"
  region  = "us-east-1"
  network = data.terraform_remote_state.network.outputs

  nodes_ami           = "ami-029f1e8b2d0665554"
  nodes_instance_type = "t4g.xlarge"
  nodes_count         = 3
  enable_metrics      = true

  # nodes_ami must be a prebaked mgx AMI (built by mgx-packer).
  # secrets_file_path defaults to ./secrets.env (the dir terraform runs from)
}
```

A runnable root is in [`examples/mgmt`](../../examples/mgmt).

For `ssh` provisioning, `secrets_file_path` defaults to `secrets.env` in the
directory terraform runs from. It is shared by every node (mgmt + storage) and
git-ignored — create it from the template before applying:

```bash
cp ../../secrets.env.example secrets.env
```

Keys: `CASS_USER`, `CASS_PASSWD`, `MGX_GW_X_API_KEY`, `MGX_X_API_KEY`,
`MGX_GW_ADMIN_PASSWD` (see the [root README](../../README.md#setup) for
descriptions).

## Key inputs

| Name | Type | Description |
|------|------|-------------|
| `cluster` | `string` | SSM namespace to discover pools from. |
| `region` | `string` | Region (pool_info.json). |
| `network` | `object` | Outputs from the network module. |
| `nodes_ami` / `nodes_instance_type` / `nodes_count` | | mgmt node fleet. |
| `enable_metrics` / `enable_grafana` | `bool` | Observability / federation. |
| `pull_http_timeout` / `push_http_timeout` | `number` | mgmt manifest tuning. |
| `provision_enabled` | `bool` | Toggle SSH provisioning. |
| `node_scripts_dir` / `provision_dir` | `string` | Baked scripts dir / dynamic-files dir on the node. |
| `secrets_file_path` | `string` | Local `secrets.env` (ssh mode). |
| `ssh_user` / `ssh_private_key_path` | `string` | SSH access via the bastion. |

## Outputs

`node_private_ips`, `instance_ids`, `discovered_pools`.
