locals {
  # format(name_format, <type>, "-<qualifier>" or "") => <prefix>-<type>-<context>[-<qualifier>]-<suffix>
  name_format = "${var.name_prefix}-%s-${var.name_context}%s-${var.name_suffix}"

  # Pinned zone IDs (e.g. to match a GWLB service) are resolved to AZ names so names/AZ letters are known at plan time.
  az_by_id = zipmap(data.aws_availability_zones.available.zone_ids, data.aws_availability_zones.available.names)
  subnet_azs = (var.az_ids == null
    ? slice(data.aws_availability_zones.available.names, 0, var.subnet_count)
    : [for id in var.az_ids : local.az_by_id[id]]
  )
}

data "aws_availability_zones" "available" {
  region = var.region
  state  = "available"
}

resource "aws_vpc" "this" {
  region               = var.region
  cidr_block           = var.cidr_block
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = {
    Name = format(local.name_format, "vpc", "")
  }
}

resource "aws_subnet" "core_attachment" {
  count             = length(local.subnet_azs)
  region            = var.region
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.cidr_block, 2, count.index)
  availability_zone = local.subnet_azs[count.index]
  tags = {
    Name = format(local.name_format, "subnet", "-attach-${substr(local.subnet_azs[count.index], -1, 1)}")
  }
}

# Network Manager is global; the VPC's region is implied by its ARN.
resource "aws_networkmanager_vpc_attachment" "this" {
  core_network_id = var.core_network_id
  vpc_arn         = aws_vpc.this.arn
  subnet_arns     = aws_subnet.core_attachment[*].arn

  options {
    appliance_mode_support = var.appliance_mode_support
  }

  # Attachment creation/acceptance has exceeded the 15m default.
  timeouts {
    create = "45m"
    update = "45m"
    delete = "45m"
  }

  tags = merge(
    { Name = format(local.name_format, "attachment", "") },
    var.attachment_tags,
  )
}

# --- Optional workload subnet, routed to Cloud WAN ---
resource "aws_subnet" "workload" {
  count             = var.create_workload_subnet ? 1 : 0
  region            = var.region
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.cidr_block, 2, 2)
  availability_zone = var.workload_az_id == null ? data.aws_availability_zones.available.names[0] : local.az_by_id[var.workload_az_id]
  tags = {
    Name = format(local.name_format, "subnet", "-workload")
  }
}

resource "aws_route_table" "workload" {
  count  = var.create_workload_subnet ? 1 : 0
  region = var.region
  vpc_id = aws_vpc.this.id
  tags = {
    Name = format(local.name_format, "rtb", "-workload")
  }
}

resource "aws_route_table_association" "workload" {
  count          = var.create_workload_subnet ? 1 : 0
  region         = var.region
  subnet_id      = aws_subnet.workload[0].id
  route_table_id = aws_route_table.workload[0].id
}

resource "aws_route" "workload_to_cloudwan" {
  count                  = var.create_workload_subnet ? 1 : 0
  region                 = var.region
  route_table_id         = aws_route_table.workload[0].id
  destination_cidr_block = var.cloudwan_destination_cidr
  core_network_arn       = var.core_network_arn

  # The core network only accepts routes from VPCs with an available attachment.
  # No create_before_destroy here: it would propagate to the attachment and its subnets, so
  # an AZ change would create the replacement subnet (same CIDR) before deleting the old one.
  depends_on = [aws_networkmanager_vpc_attachment.this]
}
