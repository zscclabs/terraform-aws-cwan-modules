output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_arn" {
  value = aws_vpc.this.arn
}

output "subnet_ids" {
  value = aws_subnet.core_attachment[*].id
}

output "attachment_id" {
  value = aws_networkmanager_vpc_attachment.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "workload_subnet_id" {
  value = one(aws_subnet.workload[*].id)
}

output "attachment_subnets" {
  description = "Cloud WAN attachment subnets as { id, az }"
  value       = [for s in aws_subnet.core_attachment : { id = s.id, az = s.availability_zone }]
}
