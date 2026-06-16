locals {

  reserved_ip_count = var.reserved_ip_count

  mgmt_nodes_per_az = {
    for az_index in range(length(var.azs)) :
    az_index => length([
      for idx in range(var.mgmt_pool.nodes_count) : idx if idx % length(var.azs) == az_index
    ])
  }

  # max mgmt IP offset used per AZ (start at 10 + floor((count-1)/AZs))
  mgmt_max_ip_offset_per_az = {
    for az_index in range(length(var.azs)) :
    az_index => 10
  }

  # storage mgmt IP start offset per AZ: after mgmt max + reserved count + 1
  storage_mgmt_start_offset_per_az = {
    for az_index in range(length(var.azs)) :
    az_index => local.mgmt_max_ip_offset_per_az[az_index] + local.reserved_ip_count + 1
  }

  sorted_pool_names = sort(keys(var.storage_pools))

  # assign each pool a fixed offset (gap * pool index)
  pool_reserved_ip_offsets = {
    for idx, pool_name in local.sorted_pool_names :
    pool_name => idx * local.reserved_ip_count
  }


  all_storage_nodes = flatten([
    for pool_name, pool in var.storage_pools : [
      for idx in range(pool.nodes_count) : {
        pool_name     = pool_name
        az_index      = idx % length(var.azs)
        index_in_pool = idx
      }
    ]
  ])

  storage_nodes_by_az = {
    for az in range(length(var.azs)) : az => [
      for node in local.all_storage_nodes : node if node.az_index == az
    ]
  }

  storage_node_ip_offsets = {
    for az, nodes in local.storage_nodes_by_az :
    az => {
      for idx, node in nodes :
      "${node.pool_name}-${node.index_in_pool}" => idx
    }
  }

  # per-AZ offsets for storage mgmt interface
  storage_node_ip_offsets_shifted = {
    for az in range(length(var.azs)) :
    az => merge([
      for pool_name, pool in var.storage_pools : {
        for idx in range(pool.nodes_count) :
        "${pool_name}-${idx}" =>
        local.pool_reserved_ip_offsets[pool_name] +
        floor(idx / length(var.azs))
        if idx % length(var.azs) == az
      }
    ]...)
  }

  storage_node_ebs_volumes = merge([
    for pool_name, pool in var.storage_pools : merge([
      for node_idx in range(pool.nodes_count) : {
        for vol_idx, vol_spec in flatten([
          for spec in pool.ebs_volumes : [
            for n in range(spec.count) : {
              size       = spec.size
              type       = spec.type
              iops       = spec.iops
              throughput = spec.throughput
            }
          ]
        ]) :
        "${pool_name}-${node_idx}-${vol_idx}" => {
          pool_name    = pool_name
          node_idx     = node_idx
          node_key     = "${pool_name}-${node_idx}"
          az_index     = node_idx % length(var.azs)
          device_index = vol_idx
          size         = vol_spec.size
          type         = vol_spec.type
          iops         = vol_spec.iops
          throughput   = vol_spec.throughput
        }
      }
    ]...)
  ]...)

  # EBS pools (raid_level == 0): owner node uuid -> [volume ids], rendered into
  # the cache config (cache_volumes) so the cache plugin groups attached EBS
  # devices by owner and the scheduler picks a drained node's volumes to move,
  # both without scanning EC2 tags. Owner uuid = uuid5(DNS, data-ip), matching
  # the cache plugin node id (uuid.uuid5(NAMESPACE_DNS, storage_data_ip)).
  cache_volumes_by_pool = {
    for pool_name, pool in var.storage_pools : pool_name => {
      for node_idx in range(pool.nodes_count) :
      uuidv5("dns", tolist(aws_network_interface.storage_secondary["${pool_name}-${node_idx}"].private_ips)[0]) => [
        for k, v in local.storage_node_ebs_volumes :
        aws_ebs_volume.storage_node[k].id
        if v.node_key == "${pool_name}-${node_idx}"
      ]
    } if pool.raid_level == 0
  }
}

resource "null_resource" "validate_nodes_count" {
  lifecycle {
    precondition {
      condition = alltrue([
        for pool in var.storage_pools :
        pool.nodes_count <= local.reserved_ip_count * length(var.azs)
      ])
      error_message = "One or more storage pools have nodes_count greater than reserved_ip_count (${local.reserved_ip_count * length(var.azs)}). Please create a new pool if you need more resources."
    }
    precondition {
      condition     = var.mgmt_pool.nodes_count <= local.reserved_ip_count * length(var.azs)
      error_message = "Management pool nodes_count (${var.mgmt_pool.nodes_count}) exceeds reserved_ip_count (${local.reserved_ip_count * length(var.azs)}). Please create a new pool if you need more resources."
    }
    precondition {
      condition = alltrue([
        for pool in var.storage_pools :
        length(var.azs) == 1
        if pool.raid_level == 0
      ])
      error_message = "Storage pools with raid_level = 0 (EBS RAID0 cache) require a single AZ (azs must have length 1), because EBS volumes and their drain/migration are AZ-bound."
    }
  }
}

resource "aws_key_pair" "deployer" {
  key_name   = "deployer-key"
  public_key = file(var.ssh_public_key_path)
}

resource "aws_eip" "nat_eip" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = var.bastion.vpc_subnet
}

resource "aws_route_table" "private_rt" {
  vpc_id = var.vpc_id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gw.id
  }
}

resource "aws_route_table_association" "mgmt_rta" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.mgmt[count.index].id
  route_table_id = aws_route_table.private_rt.id
}

resource "aws_route_table_association" "storage_rta" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.storage[count.index].id
  route_table_id = aws_route_table.private_rt.id
}

resource "aws_subnet" "mgmt" {
  count             = length(var.azs)
  vpc_id            = var.vpc_id
  cidr_block        = var.mgmt_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name    = "mgmt-subnet-${var.azs[count.index]}"
    Service = "mgx-storage"
  }
}

resource "aws_subnet" "storage" {
  count             = length(var.azs)
  vpc_id            = var.vpc_id
  cidr_block        = var.storage_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name    = "storage-subnet-${var.azs[count.index]}"
    Service = "mgx-storage"
  }
}


resource "aws_network_interface" "mgmt_primary" {
  for_each = {
    for idx in range(var.mgmt_pool.nodes_count) : "mgmt-${idx}" => {
      az_index = idx % length(var.azs)
      index    = idx
    }
  }

  subnet_id = aws_subnet.mgmt[each.value.az_index].id

  private_ips = [
    cidrhost(
      var.mgmt_subnet_cidrs[each.value.az_index],
      10 + floor(each.value.index / length(var.azs))
    )
  ]

  security_groups = [aws_security_group.allow_vpc_internal.id]

  tags = {
    Name    = "mgmt-${each.value.index}"
    Service = "mgx-storage"
  }
}


resource "aws_network_interface" "storage_primary" {
  for_each = merge([
    for pool_name, pool in var.storage_pools : {
      for idx in range(pool.nodes_count) : "${pool_name}-${idx}" => {
        az_index    = idx % length(var.azs)
        pool_name   = pool_name
        pool_config = pool
        index       = idx
      }
    }
  ]...)

  subnet_id = aws_subnet.mgmt[each.value.az_index].id

  private_ips = [
    cidrhost(
      var.mgmt_subnet_cidrs[each.value.az_index],
      local.storage_mgmt_start_offset_per_az[each.value.az_index] +
      lookup(local.storage_node_ip_offsets_shifted[each.value.az_index], each.key)
    )
  ]

  security_groups = [aws_security_group.allow_vpc_internal.id]

  tags = {
    Name    = "storage-mgmt-${each.value.pool_name}-${each.value.index}"
    Service = "mgx-storage"
  }
}


resource "aws_network_interface" "storage_secondary" {
  for_each = merge([
    for pool_name, pool in var.storage_pools : {
      for idx in range(pool.nodes_count) : "${pool_name}-${idx}" => {
        az_index  = idx % length(var.azs)
        pool_name = pool_name
        index     = idx
      }
    }
  ]...)

  subnet_id = aws_subnet.storage[each.value.az_index].id

  private_ips = [
    cidrhost(
      var.storage_subnet_cidrs[each.value.az_index],
      10 +
      lookup(local.storage_node_ip_offsets_shifted[each.value.az_index], each.key)
    )
  ]

  security_groups = [aws_security_group.allow_vpc_internal.id]

  tags = {
    Name    = "storage-data-${each.value.pool_name}-${each.value.index}"
    Service = "mgx-storage"
  }
}


resource "aws_iam_role" "storage_s3_full_access" {
  for_each = var.storage_pools

  name = "storage-${each.key}-full-access-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "s3_bucket_only" {

  for_each = {
    for k, v in var.storage_pools : k => v if length(v.s3_bucket_names) > 0 || length(v.s3_backup_bucket_names) > 0 || length(v.s3_bucket_access_names) > 0
  }

  name = "bucket-${each.key}-access-policy"
  role = aws_iam_role.storage_s3_full_access[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = concat(
          [for name in var.storage_pools[each.key].s3_bucket_names : "arn:aws:s3:::${name}"],
          [for name in var.storage_pools[each.key].s3_bucket_names : "arn:aws:s3:::${name}/*"],
          [for name in var.storage_pools[each.key].s3_backup_bucket_names : "arn:aws:s3:::${name}"],
          [for name in var.storage_pools[each.key].s3_backup_bucket_names : "arn:aws:s3:::${name}/*"],
          [for name in var.storage_pools[each.key].s3_bucket_access_names : "arn:aws:s3:::${name}"],
          [for name in var.storage_pools[each.key].s3_bucket_access_names : "arn:aws:s3:::${name}/*"]
        )
      }
    ]
  })
}

# EBS cache migration (raid_level = 0 pools): allow nodes to physically move
# their pool's cache volumes between instances during a drain. Tag-scoped to
# the pool so a node can only touch its own pool's volumes.
resource "aws_iam_role_policy" "ebs_cache_migrate" {

  for_each = {
    for k, v in var.storage_pools : k => v if v.raid_level == 0
  }

  name = "ebs-cache-${each.key}-migrate-policy"
  role = aws_iam_role.storage_s3_full_access[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Describe* actions don't support resource-level or tag conditions
        # (AWS limitation), so Resource must be "*". Narrow to the pool's
        # region, the only scoping AWS allows here.
        Effect   = "Allow"
        Action   = ["ec2:DescribeVolumes", "ec2:DescribeInstances"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = var.region
          }
        }
      },
      {
        # AttachVolume/DetachVolume authorize against BOTH the volume and the
        # instance, so both must carry Pool=<pool> (see storage_node tags).
        Effect   = "Allow"
        Action   = ["ec2:AttachVolume", "ec2:DetachVolume"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/Pool" = each.key
          }
        }
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  for_each = var.storage_pools

  name = "ec2-s3-${each.key}-instance-profile"
  role = aws_iam_role.storage_s3_full_access[each.key].name
}

resource "aws_security_group" "bastion_sg" {
  count       = var.bastion.enable ? 1 : 0
  name        = "storage-bastion-sg"
  description = "Bastion security group"

  vpc_id = var.vpc_id
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.bastion.whitelist_ips
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "allow_vpc_internal" {
  name        = "allow_vpc_internal"
  description = "Allow all traffic from the same VPC"
  vpc_id      = var.vpc_id

  ingress {
    description = "Allow all inbound traffic from VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic to VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "bastion" {
  count                       = var.bastion.enable ? 1 : 0
  ami                         = var.bastion.ami
  instance_type               = var.bastion.instance_type
  key_name                    = aws_key_pair.deployer.key_name
  vpc_security_group_ids      = [aws_security_group.bastion_sg[0].id]
  subnet_id                   = var.bastion.vpc_subnet
  associate_public_ip_address = true
  root_block_device {
    volume_size = 15
  }
  tags = {
    Name    = "storage-bastion"
    Service = "mgx-storage"
  }
}


resource "aws_instance" "mgmt_node" {
  for_each = {
    for idx in range(var.mgmt_pool.nodes_count) : "mgmt-${idx}" => {
      az_index = idx % length(var.azs)
      index    = idx
    }
  }

  ami               = var.mgmt_pool.nodes_ami
  instance_type     = var.mgmt_pool.nodes_instance_type
  key_name          = aws_key_pair.deployer.key_name
  availability_zone = var.azs[each.value.az_index]

  network_interface {
    device_index         = 0
    network_interface_id = aws_network_interface.mgmt_primary[each.key].id
  }

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name    = "mgmt-node-${each.value.index}"
    Service = "mgx-storage"
  }
}

resource "aws_instance" "storage_node" {
  for_each = merge([
    for pool_name, pool in var.storage_pools : {
      for idx in range(pool.nodes_count) : "${pool_name}-${idx}" => {
        az_index    = idx % length(var.azs)
        pool_name   = pool_name
        pool_config = pool
        index       = idx
      }
    }
  ]...)

  ami                  = each.value.pool_config.nodes_ami
  instance_type        = each.value.pool_config.nodes_instance_type
  key_name             = aws_key_pair.deployer.key_name
  iam_instance_profile = aws_iam_instance_profile.ec2_profile[each.value.pool_name].name
  availability_zone    = var.azs[each.value.az_index]

  # Primary mgmt ENI
  network_interface {
    device_index         = 0
    network_interface_id = aws_network_interface.storage_primary[each.key].id
  }

  # Secondary network interface must reference ENI ID only
  network_interface {
    device_index         = 1
    network_interface_id = aws_network_interface.storage_secondary[each.key].id
  }

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name    = "storage-node-${each.value.pool_name}-${each.value.index}"
    Service = "mgx-storage"
    # Pool tag required so ec2:AttachVolume/DetachVolume tag-scoping authorizes
    # the instance resource (the volume carries the same Pool tag).
    Pool = each.value.pool_name
  }
}


resource "aws_ebs_volume" "storage_node" {
  for_each = local.storage_node_ebs_volumes

  availability_zone = var.azs[each.value.az_index]
  size              = each.value.size
  type              = each.value.type
  iops              = each.value.iops
  throughput        = each.value.throughput

  tags = {
    Name    = "storage-${each.value.pool_name}-${each.value.node_idx}-vol-${each.value.device_index}"
    Pool    = each.value.pool_name
    Service = "mgx-storage"
  }
}

resource "aws_volume_attachment" "storage_node" {
  for_each = local.storage_node_ebs_volumes

  device_name = "/dev/sd${substr("fghijklmnopqrstuvwxyz", each.value.device_index, 1)}"
  volume_id   = aws_ebs_volume.storage_node[each.key].id
  instance_id = aws_instance.storage_node[each.value.node_key].id
}

resource "aws_s3_bucket" "s3storage" {
  for_each = {
    for pair in flatten([
      for pool_name, pool in var.storage_pools : [
        for bucket_name in pool.s3_bucket_names : {
          key           = "${pool_name}-${bucket_name}"
          bucket_name   = bucket_name
          pool_name     = pool_name
          force_destroy = pool.s3_force_destroy
        }
      ]
      ]) : pair.key => {
      bucket_name   = pair.bucket_name
      pool_name     = pair.pool_name
      force_destroy = pair.force_destroy
    }
  }

  bucket        = each.value.bucket_name
  force_destroy = each.value.force_destroy

  tags = {
    Pool    = each.value.pool_name
    Service = "mgx-storage"
  }
}

resource "aws_s3_bucket" "s3backup" {
  for_each = {
    for pair in flatten([
      for pool_name, pool in var.storage_pools : [
        for bucket_name in pool.s3_backup_bucket_names : {
          key           = "${pool_name}-${bucket_name}"
          bucket_name   = bucket_name
          pool_name     = pool_name
          force_destroy = pool.s3_force_destroy
        }
      ]
      ]) : pair.key => {
      bucket_name   = pair.bucket_name
      pool_name     = pair.pool_name
      force_destroy = pair.force_destroy
    }
  }

  bucket        = each.value.bucket_name
  force_destroy = each.value.force_destroy

  tags = {
    Pool    = each.value.pool_name
    Service = "mgx-storage"
    Role    = "backup"
  }
}
