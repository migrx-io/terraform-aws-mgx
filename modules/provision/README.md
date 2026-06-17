# modules/provision

Provisions a **single** node: stages the bootstrap scripts + `secrets.env` + any
dynamic `files` (ip lists, `pool_info.json`) under `/tmp/mgx-scripts/`, then runs
`scripts/setup-node.sh <role>`. Used by the `pool` and `mgmt` modules — they call
it once per node with `for_each`.

## Modes (`provision_mode`)

- **`ssh`** (default) — connect through the bastion, push the local scripts +
  files, and run them remotely. A `terraform_data` resource with provisioners
  that re-runs whenever a `triggers` value changes (instance id, `pool_info`
  hash). Requires `host`, `ssh_private_key_path`, `bastion_host`, `scripts_path`.
- **`ssm`** — agentless, **no bastion**. An `aws_ssm_association` runs
  `AWS-RunShellScript` on the instance: it pulls the scripts tarball from
  `scripts_url`, optionally reads `secrets.env` from `secrets_ssm_path`, writes
  the dynamic `files`, and runs setup. The association re-applies when its
  commands change (config change ⇒ re-provision). Requires `instance_id` and
  `scripts_url`, and the instance must have the SSM agent + the
  `AmazonSSMManagedInstanceCore` policy (the `pool`/`mgmt` modules attach it
  automatically when `provision_mode = "ssm"`).

The interface is the same across modes; the caller just sets `provision_mode`
and the matching inputs.

## Inputs

| Name | Mode | Default | Description |
|------|------|---------|-------------|
| `provision_mode` | both | `"ssh"` | `ssh` or `ssm`. |
| `role` | both | — | `storage` or `mgmt`. |
| `files` | both | `{}` | filename => content written into `/tmp/mgx-scripts/`. |
| `triggers` | ssh | `{}` | Change any value to force re-provisioning. |
| `host` | ssh | `""` | Node's primary/mgmt-subnet private IP. |
| `ssh_user` | ssh | `"ubuntu"` | SSH user on node + bastion. |
| `ssh_private_key_path` | ssh | `""` | Key for node and bastion. |
| `bastion_host` | ssh | `""` | Public IP of the bastion. |
| `bastion_user` | ssh | `""` | Defaults to `ssh_user`. |
| `scripts_path` | ssh | `""` | Local bootstrap scripts dir. |
| `secrets_file_path` | ssh | `"secrets.env"` | Local `secrets.env`, relative to the dir terraform runs from (copy from [`scripts/secrets.env.example`](../../scripts/secrets.env.example); git-ignored). |
| `instance_id` | ssm | `""` | EC2 instance id to target. |
| `scripts_url` | ssm | `""` | HTTPS URL of a gzipped scripts tarball. |
| `secrets_ssm_path` | ssm | `""` | SSM SecureString with `secrets.env` content. |

> The `ssm` mode has not yet been exercised end-to-end against AWS — validate it
> in a test account before relying on it.
