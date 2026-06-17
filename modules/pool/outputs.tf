output "pool_name" {
  description = "Name of this pool."
  value       = var.pool_name
}

output "node_mgmt_private_ips" {
  description = "Primary (mgmt-subnet) IPs of the pool nodes, in node-index order."
  value       = [for k in local.ordered_keys : tolist(aws_network_interface.storage_primary[k].private_ips)[0]]
}

output "node_data_private_ips" {
  description = "Secondary (data-subnet) IPs of the pool nodes, in node-index order."
  value       = [for k in local.ordered_keys : tolist(aws_network_interface.storage_secondary[k].private_ips)[0]]
}

output "instance_ids" {
  description = "EC2 instance IDs keyed by node key (<pool>-<idx>)."
  value       = { for k, inst in aws_instance.storage_node : k => inst.id }
}

output "iam_role_name" {
  description = "Name of the pool's IAM role."
  value       = aws_iam_role.node.name
}

output "ssm_registry_parameter" {
  description = "SSM parameter name where this pool publishes its node IPs/labels for the mgmt stack."
  value       = aws_ssm_parameter.pool.name
}

output "s3_bucket_names" {
  description = "S3 buckets created for block data."
  value       = [for b in aws_s3_bucket.storage : b.bucket]
}

output "s3_backup_bucket_names" {
  description = "S3 buckets created for snapshot backups."
  value       = [for b in aws_s3_bucket.backup : b.bucket]
}
