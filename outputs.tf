output "global_network_id" {
  description = "The ID of the Network Manager Global Network"
  value       = aws_networkmanager_global_network.global.id
}

output "core_network_id" {
  description = "The ID of the Cloud WAN Core Network"
  value       = aws_networkmanager_core_network.core.id
}

output "core_network_arn" {
  description = "The ARN of the Cloud WAN Core Network"
  value       = aws_networkmanager_core_network.core.arn
}

output "vpcs" {
  description = "VPCs keyed by \"<region>/<name>\""
  value = {
    for k, m in module.vpc : k => {
      vpc_id        = m.vpc_id
      subnet_ids    = m.subnet_ids
      attachment_id = m.attachment_id
    }
  }
}

output "test_instances" {
  description = "Test instances keyed by \"<region>/<segment>\""
  value = {
    for k, m in module.test_instance : k => {
      instance_id = m.instance_id
      private_ip  = m.private_ip
      eice_id     = m.eice_id
    }
  }
}

output "gwlb_endpoints" {
  description = "GWLB endpoints in inspection VPCs, keyed by \"<region>/<name>\""
  value = {
    for k, m in module.gwlb_inspection : k => {
      endpoint_ids     = m.endpoint_ids
      gwlbe_subnet_ids = m.gwlbe_subnet_ids
    }
  }
}

output "dns_forwarding" {
  description = "Route 53 Resolver outbound endpoints in segment VPCs, keyed by \"<region>/<segment>\""
  value = {
    for k, m in module.dns_forwarding : k => {
      endpoint_id      = m.endpoint_id
      endpoint_ips     = m.endpoint_ips
      forward_rule_ids = m.forward_rule_ids
      system_rule_ids  = m.system_rule_ids
    }
  }
}
