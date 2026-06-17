# These outputs form the contract consumed by the mgmt and pool modules
# (typically via terraform_remote_state). Keep names stable across versions.

output "azs" {
  description = "Availability zones, in the order subnets are indexed."
  value       = var.azs
}

output "mgmt_subnet_ids" {
  description = "Management subnet IDs, one per AZ (same order as azs)."
  value       = aws_subnet.mgmt[*].id
}

output "storage_subnet_ids" {
  description = "Storage (data) subnet IDs, one per AZ (same order as azs)."
  value       = aws_subnet.storage[*].id
}

output "mgmt_subnet_cidrs" {
  description = "Management subnet CIDRs, one per AZ (same order as azs)."
  value       = aws_subnet.mgmt[*].cidr_block
}

output "storage_subnet_cidrs" {
  description = "Storage (data) subnet CIDRs, one per AZ (same order as azs)."
  value       = aws_subnet.storage[*].cidr_block
}

output "internal_sg_id" {
  description = "Security group ID to attach to mgmt and storage node ENIs."
  value       = aws_security_group.internal.id
}

output "key_name" {
  description = "Name of the EC2 key pair created for the deployment."
  value       = aws_key_pair.deployer.key_name
}

output "bastion_enabled" {
  description = "Whether a bastion host was created."
  value       = var.bastion.enable
}

output "bastion_public_ip" {
  description = "Public IP of the bastion host, or empty string when disabled."
  value       = var.bastion.enable ? aws_instance.bastion[0].public_ip : ""
}

output "bastion_private_ip" {
  description = "Private IP of the bastion host, or empty string when disabled."
  value       = var.bastion.enable ? aws_instance.bastion[0].private_ip : ""
}
