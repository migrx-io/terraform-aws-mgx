variable "provision_mode" {
  description = "How to drive setup-node.sh on the node: 'ssh' (default, via the bastion) or 'ssm' (agentless, via SSM Run Command + no bastion)."
  type        = string
  default     = "ssh"

  validation {
    condition     = contains(["ssh", "ssm"], var.provision_mode)
    error_message = "provision_mode must be 'ssh' or 'ssm'."
  }
}

variable "role" {
  description = "Node role passed to setup-node.sh: 'storage' or 'mgmt'."
  type        = string

  validation {
    condition     = contains(["storage", "mgmt"], var.role)
    error_message = "role must be 'storage' or 'mgmt'."
  }
}

variable "files" {
  description = "Extra files (filename => content) written into /tmp/mgx-scripts/ before setup runs (e.g. pool_info.json, *_ips.txt)."
  type        = map(string)
  default     = {}
}

variable "triggers" {
  description = "Values that, when changed, force re-provisioning (e.g. instance id, hash of pool_info)."
  type        = map(string)
  default     = {}
}

# --- ssh mode -----------------------------------------------------------------

variable "host" {
  description = "[ssh] Private IP of the node to provision (its primary/mgmt-subnet address)."
  type        = string
  default     = ""
}

variable "ssh_user" {
  description = "[ssh] SSH user on the target node."
  type        = string
  default     = "ubuntu"
}

variable "ssh_private_key_path" {
  description = "[ssh] Path to the SSH private key used to reach the node (and the bastion)."
  type        = string
  default     = ""
}

variable "bastion_host" {
  description = "[ssh] Public IP/host of the bastion to tunnel through."
  type        = string
  default     = ""
}

variable "bastion_user" {
  description = "[ssh] SSH user on the bastion. Defaults to ssh_user when empty."
  type        = string
  default     = ""
}

variable "scripts_path" {
  description = "[ssh] Local path to the node bootstrap scripts directory (uploaded to the node)."
  type        = string
  default     = ""
}

variable "secrets_file_path" {
  description = "[ssh] Local path to the secrets.env file uploaded as /tmp/mgx-scripts/secrets.env. Relative paths resolve against the directory terraform runs from."
  type        = string
  default     = "secrets.env"
}

# --- ssm mode -----------------------------------------------------------------

variable "instance_id" {
  description = "[ssm] EC2 instance id to target with SSM Run Command."
  type        = string
  default     = ""
}

variable "scripts_url" {
  description = "[ssm] HTTPS URL of a gzipped tarball of the scripts directory, downloaded on the node."
  type        = string
  default     = ""
}

variable "secrets_ssm_path" {
  description = "[ssm] SSM SecureString parameter holding secrets.env content, fetched on the node."
  type        = string
  default     = ""
}
