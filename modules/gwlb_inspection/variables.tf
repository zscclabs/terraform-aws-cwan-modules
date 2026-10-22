variable "region" {
  description = "AWS region of the inspection VPC"
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  description = "Inspection VPC CIDR; GWLBe subnets take /2 split indexes 2.. (after the attachment subnets)"
  type        = string
}

variable "attachment_subnets" {
  description = "Cloud WAN attachment subnets as { id, az }; one GWLB endpoint is created per AZ"
  type = list(object({
    id = string
    az = string
  }))
}

variable "endpoint_service_name" {
  description = "GWLB endpoint service name, e.g. com.amazonaws.vpce.<region>.vpce-svc-..."
  type        = string
}

variable "core_network_arn" {
  description = "Cloud WAN core network ARN; inspected traffic returns here"
  type        = string
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
