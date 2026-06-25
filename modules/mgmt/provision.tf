# Discover downstream storage pools from SSM (each pool stack publishes
# /mgx/<cluster>/pools/<pool> = {node_ips, descr, labels}). Adding/removing a
# pool does not require editing or re-planning the mgmt stack — at most a cheap
# re-register run (see note below).
data "aws_ssm_parameters_by_path" "pools" {
  path      = "/mgx/${var.cluster}/pools/"
  recursive = true
}

locals {
  # Map basename(parameter) => decoded {node_ips, descr, labels}. values is
  # marked sensitive by the provider; these are just IPs/labels, so unwrap it.
  pool_names = [
    for name in data.aws_ssm_parameters_by_path.pools.names :
    element(split("/", name), length(split("/", name)) - 1)
  ]
  pool_values = nonsensitive(data.aws_ssm_parameters_by_path.pools.values)

  pools = {
    for i, pname in local.pool_names :
    pname => jsondecode(local.pool_values[i])
  }

  # mgmt behaviour config consumed by setup-helper.py / the mgmt manifest.
  mgmt_config = {
    nodes_ami           = var.nodes_ami
    nodes_instance_type = var.nodes_instance_type
    nodes_count         = var.nodes_count
    enable_metrics      = var.enable_metrics
    enable_grafana      = var.enable_grafana
    pull_http_timeout   = var.pull_http_timeout
    push_http_timeout   = var.push_http_timeout
  }

  pool_info_json = jsonencode({
    region    = var.region
    pool_name = "mgmt"
    config    = local.mgmt_config
    pools     = local.pools
  })

  # mgmt nodes have a single network, so the mgmt IPs double as the "data" IPs
  # (mgx-id / first-node detection then work exactly as on storage nodes).
  mgmt_ips = join("\n", [
    for k in local.ordered_keys : tolist(aws_network_interface.mgmt_primary[k].private_ips)[0]
  ])
}

module "provision" {
  source   = "../provision"
  for_each = var.provision_enabled ? aws_instance.mgmt_node : {}

  provision_mode   = var.provision_mode
  role             = "mgmt"
  node_scripts_dir = var.node_scripts_dir
  provision_dir    = var.provision_dir

  # ssh
  host                 = each.value.private_ip
  ssh_user             = var.ssh_user
  ssh_private_key_path = var.ssh_private_key_path
  bastion_host         = var.network.bastion_public_ip
  secrets_file_path    = var.secrets_file_path

  # ssm
  instance_id      = each.value.id
  secrets_ssm_path = var.secrets_ssm_path

  files = {
    "storage_mgmt_ips.txt" = local.mgmt_ips
    "storage_data_ips.txt" = local.mgmt_ips
    "pool_info.json"       = local.pool_info_json
  }

  triggers = {
    instance_id = each.value.id
    # Re-register when the mgmt config or the set of downstream pools changes.
    pool_info = sha1(local.pool_info_json)
  }
}
