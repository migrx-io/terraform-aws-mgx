locals {
  azs  = var.network.azs
  n_az = length(local.azs)

  common_tags = merge({
    Service   = "mgx-storage"
    ManagedBy = "terraform"
    Pool      = var.pool_name
  }, var.tags)

  # Node layout: round-robin across AZs, keyed "<pool>-<idx>".
  nodes = {
    for idx in range(var.nodes_count) : "${var.pool_name}-${idx}" => {
      index    = idx
      az_index = idx % local.n_az
    }
  }

  # Stable numeric ordering for the ip-list files and SSM registry. (Sorting the
  # map keys lexicographically would put "<pool>-10" before "<pool>-2".)
  ordered_keys = [for idx in range(var.nodes_count) : "${var.pool_name}-${idx}"]

  # EBS cache volumes (raid_level = 0): expand each ebs_volumes spec by its count,
  # per node, into "<pool>-<node>-<volidx>" entries.
  ebs_specs = flatten([
    for spec in var.ebs_volumes : [
      for n in range(spec.count) : {
        size       = spec.size
        type       = spec.type
        iops       = spec.iops
        throughput = spec.throughput
      }
    ]
  ])

  node_volumes = merge([
    for idx in range(var.nodes_count) : {
      for vidx, spec in local.ebs_specs :
      "${var.pool_name}-${idx}-${vidx}" => {
        node_key     = "${var.pool_name}-${idx}"
        node_idx     = idx
        az_index     = idx % local.n_az
        device_index = vidx
        size         = spec.size
        type         = spec.type
        iops         = spec.iops
        throughput   = spec.throughput
      }
    }
  ]...)

  ebs_total_count = length(var.ebs_volumes) > 0 ? sum([for s in var.ebs_volumes : s.count]) : 0
  has_s3 = (
    length(var.s3_bucket_names) +
    length(var.s3_backup_bucket_names) +
    length(var.s3_bucket_access_names)
  ) > 0
}

# Cross-variable invariants (validation blocks can't reference other vars here).
resource "terraform_data" "validate" {
  lifecycle {
    precondition {
      condition     = var.raid_level != 0 || local.n_az == 1
      error_message = "raid_level = 0 (EBS RAID0 cache) requires a single AZ, because EBS volumes are AZ-bound."
    }
    precondition {
      condition     = var.raid_level != 0 || var.nvme_node_disks_count == local.ebs_total_count
      error_message = "When raid_level = 0, nvme_node_disks_count must equal the total ebs_volumes count."
    }
  }
}

# --- ENIs (IPs auto-assigned by AWS, pinned for life by the ENI resource) ------

resource "aws_network_interface" "storage_primary" {
  for_each = local.nodes

  subnet_id       = var.network.mgmt_subnet_ids[each.value.az_index]
  security_groups = [var.network.internal_sg_id]

  tags = merge(local.common_tags, {
    Name = "storage-mgmt-${each.key}"
  })

  # Never let IP drift trigger a replacement; the ENI keeps its IP for life,
  # which is what makes node identity (uuid5 of the IP) stable across instance
  # replacement. The IP is an output, not an input.
  lifecycle {
    ignore_changes = [private_ips]
  }
}

resource "aws_network_interface" "storage_secondary" {
  for_each = local.nodes

  subnet_id       = var.network.storage_subnet_ids[each.value.az_index]
  security_groups = [var.network.internal_sg_id]

  tags = merge(local.common_tags, {
    Name = "storage-data-${each.key}"
  })

  lifecycle {
    ignore_changes = [private_ips]
  }
}

# --- IAM ----------------------------------------------------------------------

resource "aws_iam_role" "node" {
  name = "storage-${var.pool_name}-full-access-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "s3" {
  count = local.has_s3 ? 1 : 0

  name = "bucket-${var.pool_name}-access-policy"
  role = aws_iam_role.node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket"]
      Resource = concat(
        [for n in var.s3_bucket_names : "arn:aws:s3:::${n}"],
        [for n in var.s3_bucket_names : "arn:aws:s3:::${n}/*"],
        [for n in var.s3_backup_bucket_names : "arn:aws:s3:::${n}"],
        [for n in var.s3_backup_bucket_names : "arn:aws:s3:::${n}/*"],
        [for n in var.s3_bucket_access_names : "arn:aws:s3:::${n}"],
        [for n in var.s3_bucket_access_names : "arn:aws:s3:::${n}/*"],
      )
    }]
  })
}

# EBS cache migration (raid_level = 0): nodes physically move their pool's cache
# volumes between instances during a drain. Tag-scoped to this pool.
resource "aws_iam_role_policy" "ebs_cache_migrate" {
  count = var.raid_level == 0 ? 1 : 0

  name = "ebs-cache-${var.pool_name}-migrate-policy"
  role = aws_iam_role.node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Describe* can't be resource/tag scoped (AWS limitation); narrow to region.
        Effect    = "Allow"
        Action    = ["ec2:DescribeVolumes", "ec2:DescribeInstances"]
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = var.region } }
      },
      {
        # Attach/Detach authorize against both volume and instance; both carry Pool.
        Effect    = "Allow"
        Action    = ["ec2:AttachVolume", "ec2:DetachVolume"]
        Resource  = "*"
        Condition = { StringEquals = { "ec2:ResourceTag/Pool" = var.pool_name } }
      },
    ]
  })
}

resource "aws_iam_instance_profile" "node" {
  name = "ec2-s3-${var.pool_name}-instance-profile"
  role = aws_iam_role.node.name
}

# ssm provisioning: let Systems Manager Run Command reach the nodes (no bastion).
resource "aws_iam_role_policy_attachment" "ssm" {
  count = var.provision_mode == "ssm" ? 1 : 0

  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# --- S3 buckets ---------------------------------------------------------------

resource "aws_s3_bucket" "storage" {
  for_each = toset(var.s3_bucket_names)

  bucket        = each.value
  force_destroy = var.s3_force_destroy

  tags = local.common_tags
}

resource "aws_s3_bucket" "backup" {
  for_each = toset(var.s3_backup_bucket_names)

  bucket        = each.value
  force_destroy = var.s3_force_destroy

  tags = merge(local.common_tags, { Role = "backup" })
}

# --- Instances ----------------------------------------------------------------

resource "aws_instance" "storage_node" {
  for_each = local.nodes

  ami                  = var.nodes_ami
  instance_type        = var.nodes_instance_type
  key_name             = var.network.key_name
  iam_instance_profile = aws_iam_instance_profile.node.name
  availability_zone    = local.azs[each.value.az_index]

  network_interface {
    device_index         = 0
    network_interface_id = aws_network_interface.storage_primary[each.key].id
  }

  network_interface {
    device_index         = 1
    network_interface_id = aws_network_interface.storage_secondary[each.key].id
  }

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = merge(local.common_tags, {
    Name = "storage-node-${each.key}"
  })
}

resource "aws_ebs_volume" "storage_node" {
  for_each = local.node_volumes

  availability_zone = local.azs[each.value.az_index]
  size              = each.value.size
  type              = each.value.type
  iops              = each.value.iops
  throughput        = each.value.throughput

  tags = merge(local.common_tags, {
    Name = "storage-${each.value.node_key}-vol-${each.value.device_index}"
  })
}

resource "aws_volume_attachment" "storage_node" {
  for_each = local.node_volumes

  device_name = "/dev/sd${substr("fghijklmnopqrstuvwxyz", each.value.device_index, 1)}"
  volume_id   = aws_ebs_volume.storage_node[each.key].id
  instance_id = aws_instance.storage_node[each.value.node_key].id
}

# --- Pool registry (consumed by the mgmt stack via SSM) -----------------------

resource "aws_ssm_parameter" "pool" {
  name = "/mgx/${var.cluster}/pools/${var.pool_name}"
  type = "String"

  # node_ips are the nodes' primary (mgmt-subnet) IPs, reachable by the mgmt
  # plugin on MGX_PORT. Ordered by node index for determinism.
  value = jsonencode({
    node_ips = [for k in local.ordered_keys : tolist(aws_network_interface.storage_primary[k].private_ips)[0]]
    descr    = var.description
    labels   = var.labels
  })

  tags = local.common_tags
}
