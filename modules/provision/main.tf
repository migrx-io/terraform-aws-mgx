# Configures a single node by running the prebaked setup-node.sh <role> that
# already lives in the AMI (built by mgx-packer). Nothing is uploaded except the
# per-node dynamic inputs that cannot be baked: secrets.env + the ip lists +
# pool_info.json, staged under provision_dir. setup-node.sh reads them via
# MGX_PROVISION_DIR and installs nothing - it only configures the node.
#
# Two transports, selected by provision_mode:
#   ssh (default) - connect through the bastion, push the dynamic files, run.
#   ssm           - agentless: SSM Run Command writes the dynamic files (secrets
#                   from SSM) and runs setup-node.sh. No bastion required; the
#                   instance needs the SSM agent + AmazonSSMManagedInstanceCore
#                   (attached by the caller).

locals {
  is_ssh = var.provision_mode == "ssh"
  is_ssm = var.provision_mode == "ssm"

  bastion_user = var.bastion_user != "" ? var.bastion_user : var.ssh_user

  # Use `sudo env VAR=...` rather than `sudo VAR=...`: sudo's default env policy
  # strips unknown variables set the latter way, but an explicit `env` assignment
  # always applies.
  setup_cmd = "sudo env MGX_PROVISION_DIR='${var.provision_dir}' '${var.node_scripts_dir}/setup-node.sh' ${var.role}"

  # One heredoc per dynamic file, written into provision_dir. Shared by both modes.
  write_files_cmds = [
    for fname, content in var.files :
    "cat > ${var.provision_dir}/${fname} <<'MGXEOF'\n${content}\nMGXEOF"
  ]

  # Commands run on the node in ssm mode.
  ssm_commands = concat(
    [
      # AWS-RunShellScript executes under /bin/sh (dash on Ubuntu), which lacks
      # `pipefail`. Re-exec under bash so the strict-mode line below is valid.
      "[ -n \"$${BASH_VERSION:-}\" ] || exec bash \"$0\" \"$@\"",
      "set -euo pipefail",
      "mkdir -p '${var.provision_dir}'",
    ],
    var.secrets_ssm_path != "" ? [
      # The prebaked AMI is Ubuntu and ships no AWS CLI, but ssm mode needs it to
      # pull the SecureString secret (Run Command can't resolve {{ssm-secure}}).
      # Install once via snap if missing; the binary lands in /snap/bin.
      "export PATH=\"$PATH:/snap/bin\"",
      "command -v aws >/dev/null 2>&1 || snap install aws-cli --classic",
      # Pipe through `cat`: the snap CLI build throws "'NoneType' object has no
      # attribute 'flush'" when its stdout is a plain file, but is fine on a pipe.
      "aws ssm get-parameter --with-decryption --name '${var.secrets_ssm_path}' --query Parameter.Value --output text | cat > ${var.provision_dir}/secrets.env",
    ] : [],
    local.write_files_cmds,
    [
      local.setup_cmd,
    ],
  )
}

resource "terraform_data" "validate" {
  lifecycle {
    precondition {
      condition     = !local.is_ssh || (var.host != "" && var.ssh_private_key_path != "" && var.bastion_host != "")
      error_message = "ssh mode requires host, ssh_private_key_path and bastion_host."
    }
    precondition {
      condition     = !local.is_ssm || var.instance_id != ""
      error_message = "ssm mode requires instance_id."
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
    inline = ["mkdir -p '${var.provision_dir}'"]
  }

  # secrets.env is the only file uploaded from disk; the rest are dynamic
  # terraform-rendered content written by the heredocs below.
  provisioner "file" {
    source      = var.secrets_file_path
    destination = "${var.provision_dir}/secrets.env"
  }

  provisioner "remote-exec" {
    inline = local.write_files_cmds
  }

  provisioner "remote-exec" {
    inline = [local.setup_cmd]
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
