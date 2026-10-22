# Per-AZ path: Cloud WAN -> attachment subnet -> GWLBe (same AZ) -> appliance -> GWLBe -> core network.
# Requires appliance mode on the Cloud WAN attachment so both directions of a flow use the same AZ.

# The service must be offered in every attachment-subnet AZ (check with
# `aws ec2 describe-vpc-endpoint-services --region <r> --service-names <name>`).
# aws_vpc_endpoint_service can't be region-scoped in provider v6, so it isn't checked here.

locals {
  # format(name_format, <type>, "-<qualifier>" or "") => <prefix>-<type>-<context>[-<qualifier>]-<suffix>
  name_format = "${var.name_prefix}-%s-${var.name_context}%s-${var.name_suffix}"
  az_letters  = [for s in var.attachment_subnets : substr(s.az, -1, 1)]
}

resource "aws_subnet" "gwlbe" {
  count             = length(var.attachment_subnets)
  region            = var.region
  vpc_id            = var.vpc_id
  cidr_block        = cidrsubnet(var.vpc_cidr, 2, count.index + 2)
  availability_zone = var.attachment_subnets[count.index].az
  tags = {
    Name = format(local.name_format, "subnet", "-gwlbe-${local.az_letters[count.index]}")
  }
}

resource "aws_vpc_endpoint" "gwlbe" {
  count             = length(var.attachment_subnets)
  region            = var.region
  vpc_id            = var.vpc_id
  service_name      = var.endpoint_service_name
  vpc_endpoint_type = "GatewayLoadBalancer"
  subnet_ids        = [aws_subnet.gwlbe[count.index].id]
  tags = {
    Name = format(local.name_format, "vpce", "-${local.az_letters[count.index]}")
  }
}

# --- Attachment subnets: everything arriving from Cloud WAN goes to the same-AZ GWLBe ---
resource "aws_route_table" "attachment" {
  count  = length(var.attachment_subnets)
  region = var.region
  vpc_id = var.vpc_id
  tags = {
    Name = format(local.name_format, "rtb", "-attach-${local.az_letters[count.index]}")
  }
}

resource "aws_route_table_association" "attachment" {
  count          = length(var.attachment_subnets)
  region         = var.region
  subnet_id      = var.attachment_subnets[count.index].id
  route_table_id = aws_route_table.attachment[count.index].id
}

resource "aws_route" "attachment_to_gwlbe" {
  count                  = length(var.attachment_subnets)
  region                 = var.region
  route_table_id         = aws_route_table.attachment[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = aws_vpc_endpoint.gwlbe[count.index].id
}

# --- GWLBe subnets: inspected traffic goes back to Cloud WAN ---
resource "aws_route_table" "gwlbe" {
  region = var.region
  vpc_id = var.vpc_id
  tags = {
    Name = format(local.name_format, "rtb", "-gwlbe")
  }
}

resource "aws_route_table_association" "gwlbe" {
  count          = length(var.attachment_subnets)
  region         = var.region
  subnet_id      = aws_subnet.gwlbe[count.index].id
  route_table_id = aws_route_table.gwlbe.id
}

resource "aws_route" "gwlbe_to_cloudwan" {
  region                 = var.region
  route_table_id         = aws_route_table.gwlbe.id
  destination_cidr_block = "0.0.0.0/0"
  core_network_arn       = var.core_network_arn
}
