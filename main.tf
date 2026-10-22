# Deployment-wide random suffix for resource names (stable once in state).
resource "random_string" "suffix" {
  length  = var.name_suffix_length
  special = false
  upper   = false
}

# 1. AWS Network Manager Global Network
resource "aws_networkmanager_global_network" "global" {
  description = "Global Network for Cloud WAN multi-region deployment"
  tags = {
    Name = "${var.name_prefix}-globalnetwork-${local.name_suffix}"
  }
}

# 2. Cloud WAN Core Network
resource "aws_networkmanager_core_network" "core" {
  global_network_id  = aws_networkmanager_global_network.global.id
  description        = "Multi-region Cloud WAN Core Network with Inspection NFG"
  create_base_policy = false

  tags = {
    Name = "${var.name_prefix}-corenetwork-${local.name_suffix}"
  }
}

# 3. Core Network Policy Document (generated from var.regions / var.segments)
data "aws_networkmanager_core_network_policy_document" "core_policy" {
  core_network_configuration {
    vpn_ecmp_support = false
    asn_ranges       = ["64512-64555"]

    dynamic "edge_locations" {
      for_each = var.regions
      content {
        location = edge_locations.key
        asn      = edge_locations.value.asn
      }
    }
  }

  dynamic "segments" {
    for_each = var.segments
    content {
      name                          = segments.key
      description                   = segments.value
      require_attachment_acceptance = false
      # Attachments in a segment learn no routes from each other; intra-segment traffic goes via the NFG (send-via below).
      isolate_attachments = true
    }
  }

  # Network Function Group for Inspection
  network_function_groups {
    name                          = var.inspection_nfg_name
    description                   = "Central Inspection Network Function Group"
    require_attachment_acceptance = false
  }

  # Service Insertion: steer inter- and intra-segment traffic via the Inspection NFG.
  # send-via is bidirectional, so each segment lists itself plus the segments after it in sorted
  # order (one action per unordered pair, including same-segment pairs).
  # Cloud WAN forbids mixing dual-hop send-via with send-to on one NFG, so with egress inspection
  # this becomes single-hop: intra-region traffic is inspected locally, and Cloud WAN picks one
  # of the two regions for each cross-region pair.
  dynamic "segment_actions" {
    for_each = {
      for i, s in local.segment_names : s => slice(local.segment_names, i, length(local.segment_names))
    }
    content {
      action  = "send-via"
      segment = segment_actions.key
      mode    = var.egress_inspection ? "single-hop" : "dual-hop"

      when_sent_to {
        segments = segment_actions.value
      }

      via {
        network_function_groups = [var.inspection_nfg_name]
      }
    }
  }

  # Egress inspection: send-to installs 0.0.0.0/0 in each segment towards the inspection NFG.
  # No edge overrides, so each region egresses via its own inspection VPC.
  dynamic "segment_actions" {
    for_each = var.egress_inspection ? keys(var.segments) : []
    content {
      action  = "send-to"
      segment = segment_actions.value

      via {
        network_function_groups = [var.inspection_nfg_name]
      }
    }
  }

  # Tag-based Attachment Policies: Segment=<name> => segment <name>
  dynamic "attachment_policies" {
    for_each = var.segments
    content {
      rule_number     = 100 * (index(keys(var.segments), attachment_policies.key) + 1)
      condition_logic = "or"

      conditions {
        type     = "tag-value"
        operator = "equals"
        key      = "Segment"
        value    = attachment_policies.key
      }

      action {
        association_method = "constant"
        segment            = attachment_policies.key
      }
    }
  }

  attachment_policies {
    rule_number     = 1000
    condition_logic = "or"

    conditions {
      type     = "tag-value"
      operator = "equals"
      key      = "NetworkFunctionGroup"
      value    = var.inspection_nfg_name
    }

    action {
      add_to_network_function_group = var.inspection_nfg_name
    }
  }
}

# 4. Attach & Execute Policy
resource "aws_networkmanager_core_network_policy_attachment" "policy" {
  core_network_id = aws_networkmanager_core_network.core.id
  policy_document = data.aws_networkmanager_core_network_policy_document.core_policy.json
}

# 5. Regional VPCs attached to Cloud WAN
module "vpc" {
  source   = "./modules/vpc"
  for_each = local.vpcs

  region     = each.value.region
  name       = each.value.name
  cidr_block = each.value.cidr
  # Taken from the policy attachment so VPC attachments wait for edge locations to exist.
  # Avoid module-level depends_on: it defers the AZ data source and forces subnet replacement on policy edits.
  core_network_id = aws_networkmanager_core_network_policy_attachment.policy.core_network_id
  attachment_tags = each.value.tags
  az_ids          = each.value.az_ids

  core_network_arn       = aws_networkmanager_core_network.core.arn
  create_workload_subnet = var.deploy_test_instances && each.value.name != var.inspection_nfg_name
  workload_az_id         = each.value.workload_az
  appliance_mode_support = each.value.name == var.inspection_nfg_name

  # With egress inspection, the workload subnet sends everything (incl. 172.16/16) to Cloud WAN.
  cloudwan_destination_cidr = var.egress_inspection ? "0.0.0.0/0" : "172.16.0.0/16"

  name_prefix  = var.name_prefix
  name_suffix  = local.name_suffix
  name_context = each.value.context
}

# 6. Optional test instances in each segment VPC (reachable via EC2 Instance Connect Endpoint)
module "test_instance" {
  source   = "./modules/test_instance"
  for_each = local.test_vpcs

  region        = each.value.region
  name          = each.value.name
  vpc_id        = module.vpc[each.key].vpc_id
  subnet_id     = module.vpc[each.key].workload_subnet_id
  instance_type = var.test_instance_type

  zscaler_provision_key = var.zscaler_provision_key
  create_eice           = var.test_instance_eice_regions == null || contains(coalesce(var.test_instance_eice_regions, []), each.value.region)

  name_prefix  = var.name_prefix
  name_suffix  = local.name_suffix
  name_context = each.value.context
}

# 7. GWLB endpoints in inspection VPCs whose region sets gwlb_endpoint_service_name
module "gwlb_inspection" {
  source   = "./modules/gwlb_inspection"
  for_each = local.gwlb_vpcs

  region                = each.value.region
  vpc_id                = module.vpc[each.key].vpc_id
  vpc_cidr              = module.vpc[each.key].vpc_cidr
  attachment_subnets    = module.vpc[each.key].attachment_subnets
  endpoint_service_name = each.value.gwlb_service
  core_network_arn      = aws_networkmanager_core_network.core.arn

  name_prefix  = var.name_prefix
  name_suffix  = local.name_suffix
  name_context = each.value.context
}

# 8. Optional DNS conditional forwarding: Route 53 Resolver outbound endpoint + rules in each segment VPC
module "dns_forwarding" {
  source   = "./modules/dns_forwarding"
  for_each = local.dns_vpcs

  region             = each.value.region
  vpc_id             = module.vpc[each.key].vpc_id
  vpc_cidr           = module.vpc[each.key].vpc_cidr
  attachment_subnets = module.vpc[each.key].attachment_subnets
  attachment_id      = module.vpc[each.key].attachment_id
  core_network_arn   = aws_networkmanager_core_network.core.arn

  target_ips     = var.dns_forwarding.target_ips
  domain_names   = var.dns_forwarding.domain_names
  system_domains = var.dns_forwarding.system_domains

  name_prefix  = var.name_prefix
  name_suffix  = local.name_suffix
  name_context = each.value.context
}

# A warning, not a validation error, so a region's GWLB endpoints can be removed while its service is swapped.
check "egress_inspection_gwlb" {
  assert {
    condition     = !var.egress_inspection || alltrue([for r in values(var.regions) : r.gwlb_endpoint_service_name != null])
    error_message = "egress_inspection is on but a region has no gwlb_endpoint_service_name: its default and cross-region traffic sent to that region's inspection VPC is black-holed."
  }
}
