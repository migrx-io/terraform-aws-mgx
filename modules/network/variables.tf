variable "name_prefix" {
  description = "Prefix applied to resource names and the Name tag, so multiple deployments can coexist in one account."
  type        = string
  default     = "mgx-storage"
}

variable "azs" {
  description = "Availability zones to spread the management and storage subnets across."
  type        = list(string)

  validation {
    condition     = length(var.azs) > 0
    error_message = "At least one availability zone is required."
  }
}

variable "vpc_id" {
  description = "ID of the existing VPC the foundation is created in."
  type        = string
}

variable "mgmt_subnet_cidrs" {
  description = "CIDR block for each management subnet, one per entry in azs (same order)."
  type        = list(string)
}

variable "storage_subnet_cidrs" {
  description = "CIDR block for each storage (data) subnet, one per entry in azs (same order)."
  type        = list(string)
}

variable "bastion" {
  description = "Bastion host configuration. Set enable = false to skip it (e.g. when reaching nodes via SSM)."
  type = object({
    enable        = bool
    vpc_subnet    = string       # public subnet to place the bastion in
    ami           = string       # AMI id for the bastion instance
    instance_type = string       # e.g. t4g.micro
    whitelist_ips = list(string) # CIDRs allowed to SSH into the bastion
  })
  default = {
    enable        = false
    vpc_subnet    = ""
    ami           = ""
    instance_type = "t4g.micro"
    whitelist_ips = []
  }

  validation {
    condition     = !var.bastion.enable || (var.bastion.vpc_subnet != "" && var.bastion.ami != "")
    error_message = "When bastion.enable is true, bastion.vpc_subnet and bastion.ami must be set."
  }
}

variable "nat_public_subnet_id" {
  description = "Public subnet (with an internet gateway route) to place the NAT gateway in. Defaults to bastion.vpc_subnet when empty."
  type        = string
  default     = ""
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key registered as the EC2 key pair for foundation/instances."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "key_name" {
  description = "Name of the EC2 key pair to create. Make it unique per deployment to avoid collisions."
  type        = string
  default     = "mgx-deployer-key"
}

variable "tags" {
  description = "Additional tags merged onto every resource this module creates."
  type        = map(string)
  default     = {}
}
