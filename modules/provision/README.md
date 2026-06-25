# modules/provision

Configures a **single** node from the prebaked mgx AMI. The node scripts are
already baked into the image (see [`mgx-packer`](../../../mgx-packer)); this
module only stages the per-node dynamic inputs — `secrets.env` + the dynamic
`files` (ip lists, `pool_info.json`) — under `provision_dir`
(default `/tmp/mgx-provision`), then runs the baked
`<node_scripts_dir>/setup-node.sh <role>` (default `/opt/mgx/scripts`) with
`MGX_PROVISION_DIR` pointing at that dir. Nothing is installed or uploaded
beyond those dynamic files. Used by the `pool` and `mgmt` modules — they call it
once per node with `for_each`.

## Modes (`provision_mode`)

- **`ssh`** (default) — connect through the bastion, push `secrets.env` + the
  dynamic files, and run the baked `setup-node.sh`. A `terraform_data` resource
  with provisioners that re-runs whenever a `triggers` value changes (instance
  id, `pool_info` hash). Requires `host`, `ssh_private_key_path`, `bastion_host`.
- **`ssm`** — agentless, **no bastion**. An `aws_ssm_association` runs
  `AWS-RunShellScript` on the instance: it optionally reads `secrets.env` from
  `secrets_ssm_path`, writes the dynamic `files`, and runs the baked
  `setup-node.sh`. The association re-applies when its commands change (config
  change ⇒ re-provision). Requires `instance_id`, and the instance must have the
  SSM agent + the `AmazonSSMManagedInstanceCore` policy (the `pool`/`mgmt`
  modules attach it automatically when `provision_mode = "ssm"`).

The interface is the same across modes; the caller just sets `provision_mode`
and the matching inputs.

## Inputs

| Name | Mode | Default | Description |
|------|------|---------|-------------|
| `provision_mode` | both | `"ssh"` | `ssh` or `ssm`. |
| `role` | both | — | `storage` or `mgmt`. |
| `node_scripts_dir` | both | `"/opt/mgx/scripts"` | Baked scripts dir in the AMI; must match the mgx-packer build. |
| `provision_dir` | both | `"/tmp/mgx-provision"` | Writable dir for the dynamic files (read via `MGX_PROVISION_DIR`). |
| `files` | both | `{}` | filename => content written into `provision_dir`. |
| `triggers` | ssh | `{}` | Change any value to force re-provisioning. |
| `host` | ssh | `""` | Node's primary/mgmt-subnet private IP. |
| `ssh_user` | ssh | `"ubuntu"` | SSH user on node + bastion. |
| `ssh_private_key_path` | ssh | `""` | Key for node and bastion. |
| `bastion_host` | ssh | `""` | Public IP of the bastion. |
| `bastion_user` | ssh | `""` | Defaults to `ssh_user`. |
| `secrets_file_path` | ssh | `"secrets.env"` | Local `secrets.env`, relative to the dir terraform runs from (copy from [`secrets.env.example`](../../secrets.env.example); git-ignored). |
| `instance_id` | ssm | `""` | EC2 instance id to target. |
| `secrets_ssm_path` | ssm | `""` | SSM SecureString with `secrets.env` content. |
