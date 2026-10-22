variable "region" {
  description = "AWS region of the segment VPC"
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  description = "Segment VPC CIDR; resolver subnets take /3 split indexes 6.. (the 4th /2, after attachment and workload subnets)"
  type        = string
}

variable "attachment_subnets" {
  description = "Cloud WAN attachment subnets as { id, az }; one resolver subnet/endpoint IP is created per AZ"
  type = list(object({
    id = string
    az = string
  }))

  validation {
    condition     = length(var.attachment_subnets) == 2
    error_message = "Resolver endpoints need 2 IPs, and the free /26 holds exactly two /27 resolver subnets: attachment_subnets must have 2 entries."
  }
}

variable "attachment_id" {
  description = "Cloud WAN VPC attachment ID; the resolver route waits for it"
  type        = string
}

variable "core_network_arn" {
  description = "Cloud WAN core network ARN, used as the route target from the resolver subnets"
  type        = string
}

variable "target_ips" {
  description = "DNS forwarding targets (ZTGW / Cloud Connector DNS listeners)"
  type        = list(string)
}

variable "domain_names" {
  description = "key => domain forwarded to target_ips (FORWARD rules)"
  type        = map(string)
}

variable "system_domains" {
  description = "key => domain resolved by AWS (SYSTEM rules)"
  type        = map(string)
  default     = {}
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
