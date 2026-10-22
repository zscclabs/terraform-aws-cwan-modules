output "endpoint_ids" {
  value = aws_vpc_endpoint.gwlbe[*].id
}

output "gwlbe_subnet_ids" {
  value = aws_subnet.gwlbe[*].id
}
