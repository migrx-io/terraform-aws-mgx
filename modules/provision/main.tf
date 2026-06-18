# Provisions a single node by running scripts/setup-node.sh <role> on it, after
# staging the bootstrap scripts + secrets.env + dynamic files (ip lists,
# pool_info.json) under /tmp/mgx-scripts/.
#
# Two transports, selected by provision_mode:
#   ssh (default) - connect through the bastion and push files + run remotely.
#   ssm           - agentless: SSM Run Command pulls the scripts from scripts_url,
#                   reads secrets from SSM, writes the dynamic files, runs setup.
#                   No bastion required; the instance needs the SSM agent + the
#                   AmazonSSMManagedInstanceCore policy (attached by the caller).

locals {
  is_ssh = var.provision_mode == "ssh"
  is_ssm = var.provision_mode == "ssm"

  bastion_user = var.bastion_user != "" ? var.bastion_user : var.ssh_user

  # One heredoc per dynamic file, written into /tmp/mgx-scripts/ (the parent of
  # the scripts dir, where setup-helper.py expects ../<file>). Shared by both modes.
  write_files_cmds = [
    for fname, content in var.files :
    "cat > /tmp/mgx-scripts/${fname} <<'MGXEOF'\n${content}\nMGXEOF"
  ]

  # Commands run on the node in ssm mode.
  ssm_commands = concat(
    [
      "set -euo pipefail",
      "mkdir -p /tmp/mgx-scripts/scripts",
      "curl -fsSL '${var.scripts_url}' -o /tmp/mgx-scripts/scripts.tgz",
      "tar -xzf /tmp/mgx-scripts/scripts.tgz -C /tmp/mgx-scripts/scripts --strip-components=1",
    ],
    var.secrets_ssm_path != "" ? [
      "aws ssm get-parameter --with-decryption --name '${var.secrets_ssm_path}' --query Parameter.Value --output text > /tmp/mgx-scripts/secrets.env",
    ] : [],
    local.write_files_cmds,
    [
      "cd /tmp/mgx-scripts/scripts",
      "chmod +x setup-node.sh",
      "sudo ./setup-node.sh ${var.role} ${var.prebaked}",
    ],
  )
}

resource "terraform_data" "validate" {
  lifecycle {
    precondition {
      condition     = !local.is_ssh || (var.host != "" && var.ssh_private_key_path != "" && var.bastion_host != "" && var.scripts_path != "")
      error_message = "ssh mode requires host, ssh_private_key_path, bastion_host and scripts_path."
    }
    precondition {
      condition     = !local.is_ssm || (var.instance_id != "" && var.scripts_url != "")
      error_message = "ssm mode requires instance_id and scripts_url."
    }
  }
}

# --- ssh mode -----------------------------------------------------------------

resource "terraform_data" "node" {
  count = local.is_ssh ? 1 : 0

  triggers_replace = var.triggers

  connection {
    type        = "ssh"
    user        = var.ssh_user
    host        = var.host
    private_key = file(var.ssh_private_key_path)

    bastion_host        = var.bastion_host
    bastion_user        = local.bastion_user
    bastion_private_key = file(var.ssh_private_key_path)
  }

  provisioner "remote-exec" {
    inline = ["mkdir -p /tmp/mgx-scripts/scripts"]
  }

  # Trailing slash => upload the *contents* of scripts_path, so the on-node path
  # is deterministic regardless of the local directory name.
  provisioner "file" {
    source      = "${var.scripts_path}/"
    destination = "/tmp/mgx-scripts/scripts"
  }

  provisioner "file" {
    source      = var.secrets_file_path
    destination = "/tmp/mgx-scripts/secrets.env"
  }

  provisioner "remote-exec" {
    inline = local.write_files_cmds
  }

  provisioner "remote-exec" {
    inline = [
      "cd /tmp/mgx-scripts/scripts",
      "chmod +x setup-node.sh",
      "sudo ./setup-node.sh ${var.role} ${var.prebaked}",
    ]
  }
}

# --- ssm mode -----------------------------------------------------------------

# The association applies on creation and re-applies whenever its parameters
# change (the commands embed pool_info, so a config change re-provisions).
resource "aws_ssm_association" "node" {
  count = local.is_ssm ? 1 : 0

  association_name = "mgx-${var.role}-${var.instance_id}"
  name             = "AWS-RunShellScript"

  targets {
    key    = "InstanceIds"
    values = [var.instance_id]
  }

  parameters = {
    commands = join("\n", local.ssm_commands)
  }
}
