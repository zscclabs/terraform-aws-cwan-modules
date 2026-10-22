locals {
  segment_names = sort(keys(var.segments))

  # Resource names: <prefix>-<type>-<context>[-<qualifier>]-<suffix>, e.g. ztc-vpc-use1-prod-k3x9.
  name_suffix = random_string.suffix.result
  # Short region code for names: us-east-1 => use1, eu-west-2 => euw2.
  region_codes = {
    for r in keys(var.regions) : r => format("%s%s%s", split("-", r)[0], substr(split("-", r)[1], 0, 1), split("-", r)[2])
  }

  # One VPC per (region, segment) plus one inspection VPC per region, keyed "<region>/<name>".
  # Attachment tags are derived from the same names the policy document matches on.
  vpcs = merge([
    for region, cfg in var.regions : {
      for name in concat(keys(var.segments), [var.inspection_nfg_name]) :
      "${region}/${name}" => {
        region  = region
        name    = name
        context = "${local.region_codes[region]}-${name}"
        cidr    = cfg.cidrs[name]
        tags    = name == var.inspection_nfg_name ? { NetworkFunctionGroup = name } : { Segment = name }

        gwlb_service = name == var.inspection_nfg_name ? cfg.gwlb_endpoint_service_name : null
        az_ids       = name == var.inspection_nfg_name && cfg.inspection_az_ids != null ? cfg.inspection_az_ids : cfg.az_ids
        workload_az  = name == var.inspection_nfg_name ? null : cfg.workload_az_id
      }
    }
  ]...)

  # Segment (non-inspection) VPCs that get a test instance.
  test_vpcs = {
    for k, v in local.vpcs : k => v
    if var.deploy_test_instances && v.name != var.inspection_nfg_name
  }

  # Inspection VPCs whose region has a GWLB endpoint service configured.
  gwlb_vpcs = { for k, v in local.vpcs : k => v if v.gwlb_service != null }

  # Segment (non-inspection) VPCs that get a Route 53 Resolver outbound endpoint and forwarding rules.
  dns_vpcs = {
    for k, v in local.vpcs : k => v
    if var.dns_forwarding != null && v.name != var.inspection_nfg_name
  }
}
