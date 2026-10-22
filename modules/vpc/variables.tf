variable "region" {
  description = "AWS region for the VPC and subnets"
  type        = string
}

variable "name" {
  description = "Logical name (segment or NFG), used in Name tags"
  type        = string
}

variable "cidr_block" {
  description = "VPC CIDR block"
  type        = string
}

variable "core_network_id" {
  description = "Cloud WAN core network ID to attach to"
  type        = string
}

variable "attachment_tags" {
  description = "Tags on the Cloud WAN attachment; these drive segment/NFG association via the core network policy"
  type        = map(string)
}

variable "subnet_count" {
  description = "Number of attachment subnets (one per AZ); each is a /2 split of cidr_block"
  type        = number
  default     = 2

  validation {
    condition     = var.subnet_count >= 1 && var.subnet_count <= 4
    error_message = "subnet_count must be between 1 and 4."
  }
}

variable "workload_az_id" {
  description = "Zone ID (e.g. use1-az1) for the workload subnet. null = first AZ name"
  type        = string
  default     = null
}

variable "az_ids" {
  description = "Zone IDs (e.g. use1-az1) for the attachment subnets, one subnet each; overrides subnet_count. null = first subnet_count AZ names"
  type        = list(string)
  default     = null

  validation {
    condition     = var.az_ids == null || (length(var.az_ids) >= 1 && length(var.az_ids) <= 4)
    error_message = "az_ids must list between 1 and 4 zone IDs."
  }
}

variable "core_network_arn" {
  description = "Cloud WAN core network ARN, used as the route target from the workload subnet"
  type        = string
}

variable "create_workload_subnet" {
  description = "Create a workload subnet (index 2 of the /2 split) with a route to Cloud WAN"
  type        = bool
  default     = false
}

variable "cloudwan_destination_cidr" {
  description = "Destination CIDR routed from the workload subnet to the core network"
  type        = string
  default     = "172.16.0.0/16"
}

variable "appliance_mode_support" {
  description = "Enable appliance mode on the Cloud WAN attachment (keeps both directions of a flow in the same AZ; required for inspection VPCs)"
  type        = bool
  default     = false
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
