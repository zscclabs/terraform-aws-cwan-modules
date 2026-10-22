output "endpoint_id" {
  value = aws_route53_resolver_endpoint.outbound.id
}

output "endpoint_ips" {
  value = [for ip in aws_route53_resolver_endpoint.outbound.ip_address : ip.ip]
}

output "resolver_subnet_ids" {
  value = aws_subnet.resolver[*].id
}

output "forward_rule_ids" {
  value = { for k, r in aws_route53_resolver_rule.forward : k => r.id }
}

output "system_rule_ids" {
  value = { for k, r in aws_route53_resolver_rule.system : k => r.id }
}
