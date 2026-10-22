locals {
  # format(name_format, <type>, "-<qualifier>" or "") => <prefix>-<type>-<context>[-<qualifier>]-<suffix>
  name_format = "${var.name_prefix}-%s-${var.name_context}%s-${var.name_suffix}"
}

data "aws_ssm_parameter" "al2023" {
  region = var.region
  name   = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# --- Security groups (rules are separate resources to avoid an SG reference cycle) ---
# create_before_destroy: a rename replaces the SG while the old one is still attached to the instance/EICE.
resource "aws_security_group" "eice" {
  region      = var.region
  name        = format(local.name_format, "sg", "-eice")
  description = "EC2 Instance Connect Endpoint"
  vpc_id      = var.vpc_id
  tags = {
    Name = format(local.name_format, "sg", "-eice")
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "instance" {
  region      = var.region
  name        = format(local.name_format, "sg", "-instance")
  description = "Cloud WAN test instance"
  vpc_id      = var.vpc_id
  tags = {
    Name = format(local.name_format, "sg", "-instance")
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "eice_to_instance" {
  region                       = var.region
  security_group_id            = aws_security_group.eice.id
  referenced_security_group_id = aws_security_group.instance.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  tags = {
    Name = format(local.name_format, "sgr", "-ssh-to-instance")
  }
}

resource "aws_vpc_security_group_ingress_rule" "ssh_from_eice" {
  region                       = var.region
  security_group_id            = aws_security_group.instance.id
  referenced_security_group_id = aws_security_group.eice.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  tags = {
    Name = format(local.name_format, "sgr", "-ssh-from-eice")
  }
}

resource "aws_vpc_security_group_ingress_rule" "from_cloudwan" {
  region            = var.region
  security_group_id = aws_security_group.instance.id
  cidr_ipv4         = var.allowed_cidr
  ip_protocol       = "-1"
  tags = {
    Name = format(local.name_format, "sgr", "-from-cloudwan")
  }
}

resource "aws_vpc_security_group_egress_rule" "instance_all" {
  region            = var.region
  security_group_id = aws_security_group.instance.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  tags = {
    Name = format(local.name_format, "sgr", "-all-egress")
  }
}

# --- Access path: no internet in these VPCs, so SSH goes through EICE ---
# Optional: EICE is limited to 5 per account per region, and shared accounts may be at the limit.
resource "aws_ec2_instance_connect_endpoint" "this" {
  count              = var.create_eice ? 1 : 0
  region             = var.region
  subnet_id          = var.subnet_id
  security_group_ids = [aws_security_group.eice.id]
  tags = {
    Name = format(local.name_format, "eice", "")
  }
}

moved {
  from = aws_ec2_instance_connect_endpoint.this
  to   = aws_ec2_instance_connect_endpoint.this[0]
}

resource "aws_instance" "this" {
  region                      = var.region
  ami                         = data.aws_ssm_parameter.al2023.insecure_value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.instance.id]
  associate_public_ip_address = false

  # Installs Zscaler Agent Manager at first boot. Needs internet egress (dnf repos and
  # eyez-dist.private.zscaler.com) through the region's inspection appliance.
  user_data = var.zscaler_provision_key == null ? null : templatefile("${path.module}/userdata.sh.tftpl", {
    provision_key = var.zscaler_provision_key
  })
  # User data only runs at first boot, so a change must replace the instance.
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name    = format(local.name_format, "ec2", "")
    Segment = var.name
  }

  # Don't replace the instance every time a new AL2023 AMI is published.
  lifecycle {
    ignore_changes = [ami]
  }
}
