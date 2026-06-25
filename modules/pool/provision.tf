locals {
  # EBS pools (raid_level = 0): owner-node uuid -> [volume ids], rendered into
  # the cache config so the cache plugin groups attached EBS devices by owner.
  # Owner uuid = uuid5(DNS, data-ip), matching the cache plugin node id.
  cache_volumes = var.raid_level == 0 ? {
    for k in local.ordered_keys :
    uuidv5("dns", tolist(aws_network_interface.storage_secondary[k].private_ips)[0]) => [
      for vk, v in local.node_volumes :
      aws_ebs_volume.storage_node[vk].id if v.node_key == k
    ]
  } : {}

  # Full pool config consumed by setup-helper.py on the node (cache.yaml /
  # storage.yaml templates read these fields verbatim).
  pool_config = {
    description            = var.description
    labels                 = var.labels
    nodes_ami              = var.nodes_ami
    nodes_instance_type    = var.nodes_instance_type
    nodes_count            = var.nodes_count
    nvme_node_disks_count  = var.nvme_node_disks_count
    max_volumes_count      = var.max_volumes_count
    r_cache_size_in_mib    = var.r_cache_size_in_mib
    rw_cache_size_in_mib   = var.rw_cache_size_in_mib
    raid_level             = var.raid_level
    s3_bucket_names        = var.s3_bucket_names
    s3_backup_bucket_names = var.s3_backup_bucket_names
    s3_bucket_access_names = var.s3_bucket_access_names
    s3_force_destroy       = var.s3_force_destroy
    enable_metrics         = var.enable_metrics
    enable_grafana         = var.enable_grafana
    cross_peer_scrape      = var.cross_peer_scrape
    ebs_volumes            = var.ebs_volumes
  }

  pool_info_json = jsonencode({
    region    = var.region
    pool_name = var.pool_name
    config    = merge(local.pool_config, { cache_volumes = local.cache_volumes })
  })

  storage_mgmt_ips = join("\n", [
    for k in local.ordered_keys : tolist(aws_network_interface.storage_primary[k].private_ips)[0]
  ])
  storage_data_ips = join("\n", [
    for k in local.ordered_keys : tolist(aws_network_interface.storage_secondary[k].private_ips)[0]
  ])
}

module "provision" {
  source   = "../provision"
  for_each = var.provision_enabled ? aws_instance.storage_node : {}

  provision_mode   = var.provision_mode
  role             = "storage"
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
    "storage_mgmt_ips.txt" = local.storage_mgmt_ips
    "storage_data_ips.txt" = local.storage_data_ips
    "pool_info.json"       = local.pool_info_json
  }

  triggers = {
    instance_id = each.value.id
    pool_info   = sha1(local.pool_info_json)
  }

  depends_on = [aws_volume_attachment.storage_node]
}
