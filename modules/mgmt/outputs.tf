output "node_private_ips" {
  description = "Private IPs of the mgmt nodes, in node-index order."
  value       = [for k in local.ordered_keys : tolist(aws_network_interface.mgmt_primary[k].private_ips)[0]]
}

output "instance_ids" {
  description = "EC2 instance IDs keyed by node key (mgmt-<idx>)."
  value       = { for k, inst in aws_instance.mgmt_node : k => inst.id }
}

output "discovered_pools" {
  description = "Pool names discovered from SSM and registered with the mgmt plane."
  value       = sort(local.pool_names)
}
