variable "region" {
  description = "AWS region for the instance"
  type        = string
}

variable "name" {
  description = "Segment name, used in Name/Segment tags"
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  description = "Subnet for the instance and the EC2 Instance Connect Endpoint"
  type        = string
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "zscaler_provision_key" {
  description = "Zscaler Agent Manager provision key; when set, user data installs the agent at first boot"
  type        = string
  default     = null
  sensitive   = true
}

variable "allowed_cidr" {
  description = "CIDR allowed to reach the instance (ICMP and all traffic) over Cloud WAN"
  type        = string
  default     = "172.16.0.0/16"
}

variable "create_eice" {
  description = "Create an EC2 Instance Connect Endpoint in this VPC"
  type        = bool
  default     = true
}

variable "name_prefix" {
  description = "Prefix for resource names (<prefix>-<type>-<context>-<suffix>)"
  type        = string
}

variable "name_suffix" {
  description = "Deployment-wide random suffix for resource names"
  type        = string
}

variable "name_context" {
  description = "Region code and VPC name used in resource names, e.g. use1-prod"
  type        = string
}
