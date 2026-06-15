# Run on mgmt and storage nodes

resource "null_resource" "provision_mgmt" {
  for_each = aws_instance.mgmt_node

  depends_on = [
    aws_instance.bastion,
    aws_instance.mgmt_node,
    aws_nat_gateway.nat_gw,
  ]

  connection {
    type        = "ssh"
    user        = var.ssh_user
    host        = each.value.private_ip
    private_key = file(var.ssh_private_key_path)

    bastion_host        = aws_instance.bastion[0].public_ip
    bastion_user        = var.ssh_user
    bastion_private_key = file(var.ssh_private_key_path)
  }

  # Create /tmp/scripts directory
  provisioner "remote-exec" {
    inline = [
      "mkdir -p /tmp/mgx-scripts"
    ]
  }

  provisioner "file" {
    source      = "../scripts"
    destination = "/tmp/mgx-scripts"
  }

  provisioner "file" {
    source      = "./envs/${var.region}/secrets.env"
    destination = "/tmp/mgx-scripts/secrets.env"
  }

  provisioner "remote-exec" {
    inline = [
      <<EOC

  echo '${join("\n", [for ni in aws_network_interface.mgmt_primary : tolist(ni.private_ips)[0]])}' > /tmp/mgx-scripts/storage_mgmt_ips.txt

  # mgmt nodes have a single network, so reuse the mgmt IPs as the "data" IPs:
  # mgx-id and first-node detection then work exactly as on storage nodes.
  echo '${join("\n", [for ni in aws_network_interface.mgmt_primary : tolist(ni.private_ips)[0]])}' > /tmp/mgx-scripts/storage_data_ips.txt

  cat > /tmp/mgx-scripts/pool_info.json <<'EOF'
  ${jsonencode({
      region    = var.region,
      pool_name = "mgmt",
      config    = var.mgmt_pool,
      # Downstream pools to register in the mgmt plugin. node_ips are the storage
      # nodes' primary (mgmt-subnet) IPs, reachable from the mgmt node on MGX_PORT.
      pools = {
        for pool_name in keys(var.storage_pools) :
        pool_name => {
          node_ips = [
            for idx in range(var.storage_pools[pool_name].nodes_count) :
            tolist(aws_network_interface.storage_primary["${pool_name}-${idx}"].private_ips)[0]
          ]
          descr  = var.storage_pools[pool_name].description
          labels = var.storage_pools[pool_name].labels
        }
      }
})}

  EOC
]
}

provisioner "remote-exec" {
  inline = [
    "cd /tmp/mgx-scripts/scripts",
    "chmod +x setup-mgmt.sh",
    "sudo ./setup-mgmt.sh",
    # "cd /tmp && rm -rf /tmp/mgx-scripts"
  ]
}
}

# Run on storage nodes
resource "null_resource" "provision_storage" {
  for_each = aws_instance.storage_node

  depends_on = [
    aws_instance.bastion,
    aws_instance.storage_node,
    aws_nat_gateway.nat_gw,
    aws_volume_attachment.storage_node,
  ]

  connection {
    type        = "ssh"
    user        = var.ssh_user
    host        = each.value.private_ip
    private_key = file(var.ssh_private_key_path)

    bastion_host        = aws_instance.bastion[0].public_ip
    bastion_user        = var.ssh_user
    bastion_private_key = file(var.ssh_private_key_path)
  }

  # Create /tmp/scripts directory
  provisioner "remote-exec" {
    inline = [
      "mkdir -p /tmp/mgx-scripts"
    ]
  }

  provisioner "file" {
    source      = "../scripts"
    destination = "/tmp/mgx-scripts"
  }

  provisioner "file" {
    source      = "./envs/${var.region}/secrets.env"
    destination = "/tmp/mgx-scripts/secrets.env"
  }

  provisioner "remote-exec" {
    inline = [
      <<EOC

  echo '${join("\n", [
      for k, eni in aws_network_interface.storage_primary :
      tolist(eni.private_ips)[0] if startswith(k, split("-", each.key)[0])
      ])}' > /tmp/mgx-scripts/storage_mgmt_ips.txt

  echo '${join("\n", [
      for k, eni in aws_network_interface.storage_secondary :
      tolist(eni.private_ips)[0] if startswith(k, split("-", each.key)[0])
      ])}' > /tmp/mgx-scripts/storage_data_ips.txt

  cat > /tmp/mgx-scripts/pool_info.json <<'EOF'
  ${jsonencode({
      region    = var.region,
      pool_name = split("-", each.key)[0],
      config = merge(
        var.storage_pools[split("-", each.key)[0]],
        {
          cache_volumes = lookup(local.cache_volumes_by_pool, split("-", each.key)[0], {})
        }
      )
})}

  EOC
]
}

provisioner "remote-exec" {
  inline = [
    "cd /tmp/mgx-scripts/scripts",
    "chmod +x setup-storage.sh",
    "sudo ./setup-storage.sh",
    # "cd /tmp && rm -rf /tmp/mgx-scripts"
  ]
}
}
