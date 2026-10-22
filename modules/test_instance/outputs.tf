output "instance_id" {
  value = aws_instance.this.id
}

output "private_ip" {
  value = aws_instance.this.private_ip
}

output "eice_id" {
  value = one(aws_ec2_instance_connect_endpoint.this[*].id)
}
