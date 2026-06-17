locals {
  common_tags = merge({
    Service   = "mgx-storage"
    ManagedBy = "terraform"
  }, var.tags)

  # NAT lives in a public subnet, independent of whether the bastion exists.
  nat_subnet_id = var.nat_public_subnet_id != "" ? var.nat_public_subnet_id : var.bastion.vpc_subnet
}

# Cross-variable invariants (kept here because variable validation blocks may
# not reference other variables on the supported Terraform versions).
resource "terraform_data" "validate" {
  lifecycle {
    precondition {
      condition     = length(var.mgmt_subnet_cidrs) == length(var.azs)
      error_message = "mgmt_subnet_cidrs must have exactly one CIDR per availability zone."
    }
    precondition {
      condition     = length(var.storage_subnet_cidrs) == length(var.azs)
      error_message = "storage_subnet_cidrs must have exactly one CIDR per availability zone."
    }
    precondition {
      condition     = local.nat_subnet_id != ""
      error_message = "A public subnet for the NAT gateway is required: set nat_public_subnet_id or bastion.vpc_subnet."
    }
  }
}

resource "aws_key_pair" "deployer" {
  key_name   = var.key_name
  public_key = file(var.ssh_public_key_path)

  tags = local.common_tags
}

# --- Subnets: one management + one storage (data) subnet per AZ ---------------

resource "aws_subnet" "mgmt" {
  count             = length(var.azs)
  vpc_id            = var.vpc_id
  cidr_block        = var.mgmt_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-mgmt-${var.azs[count.index]}"
    Tier = "mgmt"
  })
}

resource "aws_subnet" "storage" {
  count             = length(var.azs)
  vpc_id            = var.vpc_id
  cidr_block        = var.storage_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-storage-${var.azs[count.index]}"
    Tier = "storage"
  })
}

# --- Egress: single NAT gateway + private route table for both subnet tiers ---

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-nat"
  })
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = local.nat_subnet_id

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-nat"
  })
}

resource "aws_route_table" "private" {
  vpc_id = var.vpc_id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-private"
  })
}

resource "aws_route_table_association" "mgmt" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.mgmt[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "storage" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.storage[count.index].id
  route_table_id = aws_route_table.private.id
}

# --- Security groups ----------------------------------------------------------

# Shared by mgmt + storage ENIs. Intra-VPC traffic is open; egress is open so
# nodes can reach the NAT gateway. Exported as internal_sg_id for other modules.
resource "aws_security_group" "internal" {
  name        = "${var.name_prefix}-internal"
  description = "Allow all traffic within the VPC for mgx-storage nodes"
  vpc_id      = var.vpc_id

  ingress {
    description = "All inbound from VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-internal"
  })
}

resource "aws_security_group" "bastion" {
  count       = var.bastion.enable ? 1 : 0
  name        = "${var.name_prefix}-bastion"
  description = "SSH access to the bastion host"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH from whitelisted CIDRs"
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

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-bastion"
  })
}

# --- Bastion host -------------------------------------------------------------

resource "aws_instance" "bastion" {
  count                       = var.bastion.enable ? 1 : 0
  ami                         = var.bastion.ami
  instance_type               = var.bastion.instance_type
  key_name                    = aws_key_pair.deployer.key_name
  vpc_security_group_ids      = [aws_security_group.bastion[0].id]
  subnet_id                   = var.bastion.vpc_subnet
  associate_public_ip_address = true

  root_block_device {
    volume_size = 15
  }

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-bastion"
  })
}
