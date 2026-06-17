variable "cluster" {
  description = "Logical cluster name. The mgmt nodes discover pools from SSM under /mgx/<cluster>/pools/."
  type        = string
  default     = "main"
}

variable "region" {
  description = "AWS region (written into pool_info.json)."
  type        = string
}

variable "network" {
  description = "Outputs from the network module (typically via terraform_remote_state)."
  type = object({
    azs               = list(string)
    mgmt_subnet_ids   = list(string)
    internal_sg_id    = string
    key_name          = string
    bastion_public_ip = string
  })
}

# --- mgmt nodes ---------------------------------------------------------------

variable "nodes_ami" {
  description = "AMI for the mgmt nodes."
  type        = string
}

variable "nodes_instance_type" {
  description = "EC2 instance type for the mgmt nodes."
  type        = string
}

variable "nodes_count" {
  description = "Number of mgmt nodes."
  type        = number

  validation {
    condition     = var.nodes_count >= 1
    error_message = "nodes_count must be at least 1."
  }
}

variable "enable_metrics" {
  description = "Run node_exporter/prometheus on the mgmt nodes (also federates pool prometheus)."
  type        = bool
  default     = false
}

variable "enable_grafana" {
  description = "Run grafana (VIP service) on the mgmt nodes."
  type        = bool
  default     = false
}

variable "pull_http_timeout" {
  description = "mgmt plugin pull HTTP timeout (seconds), rendered into the mgmt manifest."
  type        = number
  default     = 30
}

variable "push_http_timeout" {
  description = "mgmt plugin push HTTP timeout (seconds), rendered into the mgmt manifest."
  type        = number
  default     = 30
}

# --- Provisioning -------------------------------------------------------------

variable "provision_enabled" {
  description = "Run node provisioning. Set false to create infrastructure only."
  type        = bool
  default     = true
}

variable "provision_mode" {
  description = "Provisioning transport: 'ssh' (default, via the bastion) or 'ssm' (agentless, no bastion)."
  type        = string
  default     = "ssh"

  validation {
    condition     = contains(["ssh", "ssm"], var.provision_mode)
    error_message = "provision_mode must be 'ssh' or 'ssm'."
  }
}

variable "scripts_path" {
  description = "[ssh] Local path to the node bootstrap scripts directory."
  type        = string
  default     = ""
}

variable "secrets_file_path" {
  description = "[ssh] Local path to the secrets.env uploaded to nodes."
  type        = string
  default     = ""
}

variable "ssh_user" {
  description = "[ssh] SSH user on the nodes and bastion."
  type        = string
  default     = "ubuntu"
}

variable "ssh_private_key_path" {
  description = "[ssh] Path to the SSH private key used to reach nodes via the bastion."
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "scripts_url" {
  description = "[ssm] HTTPS URL of a gzipped tarball of the scripts directory, pulled on the node."
  type        = string
  default     = ""
}

variable "secrets_ssm_path" {
  description = "[ssm] SSM SecureString parameter holding secrets.env content."
  type        = string
  default     = ""
}

variable "root_volume_size" {
  description = "Root EBS volume size (GiB) for mgmt nodes."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Additional tags merged onto every resource."
  type        = map(string)
  default     = {}
}
