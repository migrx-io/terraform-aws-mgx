locals {
  azs  = var.network.azs
  n_az = length(local.azs)

  common_tags = merge({
    Service   = "mgx-storage"
    ManagedBy = "terraform"
    Pool      = "mgmt"
  }, var.tags)

  nodes = {
    for idx in range(var.nodes_count) : "mgmt-${idx}" => {
      index    = idx
      az_index = idx % local.n_az
    }
  }

  ordered_keys = [for idx in range(var.nodes_count) : "mgmt-${idx}"]
}

# ssm provisioning: mgmt nodes have no IAM role by default, so create a minimal
# SSM-managed role + instance profile only when provisioning over SSM.
resource "aws_iam_role" "node" {
  count = var.provision_mode == "ssm" ? 1 : 0

  name = "mgmt-${var.cluster}-ssm-role"

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

resource "aws_iam_role_policy_attachment" "ssm" {
  count = var.provision_mode == "ssm" ? 1 : 0

  role       = aws_iam_role.node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "node" {
  count = var.provision_mode == "ssm" ? 1 : 0

  name = "mgmt-${var.cluster}-ssm-instance-profile"
  role = aws_iam_role.node[0].name
}

# --- mgmt node ENIs (single interface; IPs auto-assigned, pinned by the ENI) ---

resource "aws_network_interface" "mgmt_primary" {
  for_each = local.nodes

  subnet_id       = var.network.mgmt_subnet_ids[each.value.az_index]
  security_groups = [var.network.internal_sg_id]

  tags = merge(local.common_tags, {
    Name = each.key
  })

  lifecycle {
    ignore_changes = [private_ips]
  }
}

resource "aws_instance" "mgmt_node" {
  for_each = local.nodes

  ami                  = var.nodes_ami
  instance_type        = var.nodes_instance_type
  key_name             = var.network.key_name
  availability_zone    = local.azs[each.value.az_index]
  iam_instance_profile = var.provision_mode == "ssm" ? aws_iam_instance_profile.node[0].name : null

  network_interface {
    device_index         = 0
    network_interface_id = aws_network_interface.mgmt_primary[each.key].id
  }

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = merge(local.common_tags, {
    Name = "mgmt-node-${each.value.index}"
  })
}
