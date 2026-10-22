# Conditional DNS forwarding from one segment VPC via a Route 53 Resolver outbound endpoint.
# Query path: resolver ENI -> core network -> segment 0.0.0.0/0 (send-to) -> local inspection VPC
# -> same-AZ GWLBe -> ZTGW / Cloud Connector DNS listener. Requires egress_inspection.

locals {
  # format(name_format, <type>, "-<qualifier>" or "") => <prefix>-<type>-<context>[-<qualifier>]-<suffix>
  name_format = "${var.name_prefix}-%s-${var.name_context}%s-${var.name_suffix}"
  az_letters  = [for s in var.attachment_subnets : substr(s.az, -1, 1)]

  # FORWARD/SYSTEM rule targets: one egress rule per (target, protocol).
  dns_egress = {
    for p in setproduct(var.target_ips, ["udp", "tcp"]) : "${p[1]}-${p[0]}" => { ip = p[0], protocol = p[1] }
  }
}

# --- Resolver subnets: the free 4th /26 (after attachment a/b and workload) split into two /27s,
# in the attachment subnets' AZs ---
resource "aws_subnet" "resolver" {
  count             = length(var.attachment_subnets)
  region            = var.region
  vpc_id            = var.vpc_id
  cidr_block        = cidrsubnet(var.vpc_cidr, 3, count.index + 6)
  availability_zone = var.attachment_subnets[count.index].az
  tags = {
    Name = format(local.name_format, "subnet", "-resolver-${local.az_letters[count.index]}")
  }
}

resource "aws_route_table" "resolver" {
  region = var.region
  vpc_id = var.vpc_id
  tags = {
    Name = format(local.name_format, "rtb", "-resolver")
  }
}

resource "aws_route_table_association" "resolver" {
  count          = length(var.attachment_subnets)
  region         = var.region
  subnet_id      = aws_subnet.resolver[count.index].id
  route_table_id = aws_route_table.resolver.id
}

resource "aws_route" "resolver_to_cloudwan" {
  region                 = var.region
  route_table_id         = aws_route_table.resolver.id
  destination_cidr_block = "0.0.0.0/0"
  core_network_arn       = var.core_network_arn

  # The core network only accepts routes from VPCs with an available attachment.
  # No create_before_destroy (see modules/vpc workload route).
  depends_on = [var.attachment_id]
}

# --- Endpoint security group: DNS to the forwarding targets only ---
# create_before_destroy: a rename replaces the SG while the old one is still attached to the endpoint.
resource "aws_security_group" "endpoint" {
  region      = var.region
  name        = format(local.name_format, "sg", "-r53ep")
  description = "Route 53 Resolver outbound endpoint"
  vpc_id      = var.vpc_id
  tags = {
    Name = format(local.name_format, "sg", "-r53ep")
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "dns" {
  for_each          = local.dns_egress
  region            = var.region
  security_group_id = aws_security_group.endpoint.id
  cidr_ipv4         = "${each.value.ip}/32"
  ip_protocol       = each.value.protocol
  from_port         = 53
  to_port           = 53
  tags = {
    Name = format(local.name_format, "sgr", "-dns-${each.key}")
  }
}

# --- Outbound endpoint (one IP per resolver subnet) ---
# No create_before_destroy: it would propagate to the resolver subnets, whose replacements reuse the same CIDRs.
resource "aws_route53_resolver_endpoint" "outbound" {
  region             = var.region
  name               = format(local.name_format, "r53ep", "")
  direction          = "OUTBOUND"
  protocols          = ["Do53"]
  security_group_ids = [aws_security_group.endpoint.id]

  dynamic "ip_address" {
    for_each = aws_subnet.resolver[*].id
    content {
      subnet_id = ip_address.value
    }
  }

  tags = {
    Name = format(local.name_format, "r53ep", "")
  }

  # Queries can't leave until the subnets route to Cloud WAN.
  depends_on = [aws_route.resolver_to_cloudwan, aws_route_table_association.resolver]
}

# --- FORWARD rules: steer the listed domains to the ZTGW / Cloud Connector ---
resource "aws_route53_resolver_rule" "forward" {
  for_each             = var.domain_names
  region               = var.region
  domain_name          = each.value
  name                 = format(local.name_format, "r53rule", "-${each.key}")
  rule_type            = "FORWARD"
  resolver_endpoint_id = aws_route53_resolver_endpoint.outbound.id

  dynamic "target_ip" {
    for_each = var.target_ips
    content {
      ip   = target_ip.value
      port = 53
    }
  }

  tags = {
    Name = format(local.name_format, "r53rule", "-${each.key}")
  }
}

resource "aws_route53_resolver_rule_association" "forward" {
  for_each         = var.domain_names
  region           = var.region
  name             = format(local.name_format, "r53assoc", "-${each.key}")
  resolver_rule_id = aws_route53_resolver_rule.forward[each.key].id
  vpc_id           = var.vpc_id
}

# --- SYSTEM rules: AWS resolves these recursively (e.g. Zscaler's own domains), overriding
# any broader FORWARD rule ---
resource "aws_route53_resolver_rule" "system" {
  for_each    = var.system_domains
  region      = var.region
  domain_name = each.value
  name        = format(local.name_format, "r53rule", "-sys-${each.key}")
  rule_type   = "SYSTEM"

  tags = {
    Name = format(local.name_format, "r53rule", "-sys-${each.key}")
  }
}

resource "aws_route53_resolver_rule_association" "system" {
  for_each         = var.system_domains
  region           = var.region
  name             = format(local.name_format, "r53assoc", "-sys-${each.key}")
  resolver_rule_id = aws_route53_resolver_rule.system[each.key].id
  vpc_id           = var.vpc_id
}
