variable "aws_profile" {
  description = "AWS CLI profile for the provider. null = default credential chain (env vars, SSO, instance role). Set it in the untracked terraform.tfvars"
  type        = string
  default     = null
}

variable "home_region" {
  description = "Default provider region, used for global Network Manager resources"
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for every resource name: <prefix>-<type>-<context>-<random suffix>"
  type        = string
  default     = "ztc"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,15}$", var.name_prefix))
    error_message = "name_prefix must be 1-16 lowercase letters, digits or hyphens, starting with a letter or digit."
  }
}

variable "name_suffix_length" {
  description = "Length of the random lowercase alphanumeric suffix appended to every resource name (changing it renames everything)"
  type        = number
  default     = 4

  validation {
    condition     = var.name_suffix_length >= 3 && var.name_suffix_length <= 8
    error_message = "name_suffix_length must be between 3 and 8."
  }
}

variable "segments" {
  description = "Cloud WAN segments (name => description). Each gets a VPC per region tagged Segment=<name>"
  type        = map(string)
  default = {
    prod = "Production Workload Segment"
    dev  = "Development Workload Segment"
  }
}

variable "inspection_nfg_name" {
  description = "Name of the inspection Network Function Group; also the CIDR key for inspection VPCs"
  type        = string
  default     = "inspection"
}

variable "regions" {
  description = "Cloud WAN edge locations: region => edge ASN and a CIDR per segment plus the inspection NFG"
  type = map(object({
    asn   = number
    cidrs = map(string)
    # Optional GWLB endpoint service; when set, the region's inspection VPC gets GWLB endpoints.
    gwlb_endpoint_service_name = optional(string)
    # Optional zone IDs for the attachment subnets of every VPC in the region (one subnet per zone).
    az_ids = optional(list(string))
    # Optional override of az_ids for the inspection VPC only; must be AZs the GWLB service is offered in.
    inspection_az_ids = optional(list(string))
    # Optional zone ID for the segment VPCs' workload subnet (test instances); null = first AZ name.
    workload_az_id = optional(string)
  }))
  default = {
    "us-east-1" = {
      asn = 64512
      cidrs = {
        prod       = "172.16.0.0/24"
        dev        = "172.16.10.0/24"
        inspection = "172.16.20.0/24"
      }
    }
    "us-west-2" = {
      asn = 64513
      cidrs = {
        prod       = "172.16.1.0/24"
        dev        = "172.16.11.0/24"
        inspection = "172.16.21.0/24"
      }
    }
  }

  validation {
    condition     = alltrue([for r in values(var.regions) : r.asn >= 64512 && r.asn <= 64555])
    error_message = "Each region's asn must be within the core network asn_ranges (64512-64555)."
  }

  validation {
    condition = alltrue([
      for r in values(var.regions) :
      length(setsubtract(concat(keys(var.segments), [var.inspection_nfg_name]), keys(r.cidrs))) == 0
    ])
    error_message = "Each region's cidrs must contain a key for every segment and for the inspection NFG."
  }
}

variable "deploy_test_instances" {
  description = "Deploy a test instance (plus workload subnet, Cloud WAN route and EC2 Instance Connect Endpoint) in each segment VPC"
  type        = bool
  default     = false
}

variable "zscaler_provision_key" {
  description = "Zscaler Agent Manager provision key for the test instances' user data. null = no user data. Never commit it: set it in the untracked terraform.tfvars or via TF_VAR_zscaler_provision_key"
  type        = string
  default     = null
  sensitive   = true
}

variable "test_instance_type" {
  description = "Instance type for test instances"
  type        = string
  default     = "t3.micro"
}

variable "test_instance_eice_regions" {
  description = "Regions whose test VPCs get an EC2 Instance Connect Endpoint (null = all). EICE quota is 5 per account per region"
  type        = list(string)
  default     = null
}

variable "egress_inspection" {
  description = "Install 0.0.0.0/0 in every segment towards the inspection NFG; each region egresses via its own inspection VPC. Also makes east-west send-via single-hop"
  type        = bool
  default     = false
}

variable "dns_forwarding" {
  description = "Route 53 Resolver conditional forwarding: an outbound endpoint in every segment VPC forwards domain_names to target_ips (ZTGW / Cloud Connector) via the local inspection VPC. null = off. Requires egress_inspection"
  type = object({
    target_ips     = list(string)
    domain_names   = map(string)
    system_domains = optional(map(string), {})
  })
  default = null

  validation {
    condition     = var.dns_forwarding == null || var.egress_inspection
    error_message = "dns_forwarding requires egress_inspection = true: the forwarding targets are reached via each segment's 0.0.0.0/0 send-to route."
  }

  validation {
    condition = var.dns_forwarding == null || (
      length(var.dns_forwarding.target_ips) >= 1 && length(var.dns_forwarding.target_ips) <= 6 &&
      alltrue([for ip in var.dns_forwarding.target_ips : can(regex("^(\\d{1,3}\\.){3}\\d{1,3}$", ip)) && can(cidrhost("${ip}/32", 0))])
    )
    error_message = "dns_forwarding.target_ips must hold 1-6 IPv4 addresses."
  }

  validation {
    condition = var.dns_forwarding == null || alltrue([
      for k in concat(keys(var.dns_forwarding.domain_names), keys(var.dns_forwarding.system_domains)) : can(regex("^[a-z0-9-]{1,20}$", k))
    ])
    error_message = "dns_forwarding domain keys are used in resource names: 1-20 lowercase letters, digits or hyphens."
  }
}
