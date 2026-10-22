# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Terraform root configuration that deploys an AWS Cloud WAN core network across multiple regions (default: us-east-1, us-west-2), with workload segments (`prod`, `dev`) whose inter- and intra-segment traffic is steered through a per-region `inspection` Network Function Group (NFG) backed by GWLB endpoints (Zscaler ZTGW / Cloud Connector). Internet egress and, optionally, conditional DNS forwarding (Route 53 Resolver outbound endpoints) go through the same regional inspection path. Requires Terraform >= 1.9 (cross-variable validation) and AWS provider `~> 6.0`.

## Commands

```sh
terraform init
terraform fmt -recursive
terraform validate
terraform plan    # terraform.tfvars is auto-loaded; copy terraform.tfvars.example to create it
terraform apply
terraform output test_instances   # instance IDs / IPs
terraform output dns_forwarding   # resolver endpoint IDs / IPs and rule IDs
```

**Secrets and private data.**
- Never commit credentials or deployment-specific values: real account IDs, resource IDs, service names, public IPs, domains or profile names.
- Real inputs live in the untracked `terraform.tfvars`. The provision key goes there or in `TF_VAR_zscaler_provision_key`. The AWS profile is `var.aws_profile`.
- `terraform.tfvars.example` holds placeholders only.
- Gitignored: state, `terraform.tfvars`, `*.auto.tfvars`, `private/` (the deployment's own architecture doc, handoff, policy analysis and policy JSON) and `CLAUDE.local.md` (deployment notes).
- Check with `git ls-files | xargs grep -nE '<pattern>'` before committing.

There are no tests or CI. Note that `terraform validate` does **not** catch invalid arguments inside `aws_networkmanager_core_network_policy_document`; to check the policy, render it with `plan` and inspect the JSON, or check the provider schema with `terraform providers schema -json`.

## Architecture

Everything is driven by three inputs in `variables.tf`:
- `regions`: region => `{ asn, cidrs = { <segment>|<nfg> = cidr } }`
- `segments`: name => description
- `inspection_nfg_name`

**Single provider, per-resource region.** There are no provider aliases. AWS provider v6's `region` argument is set on each regional resource (`aws_vpc`, `aws_subnet`, `aws_availability_zones`) in `modules/vpc`. That's what allows `for_each` over regions. Network Manager resources are global and take no `region`.

**Root `main.tf`:**
- global network → core network (`create_base_policy = false`) → policy attachment.
- The policy document is built entirely with `dynamic` blocks:
  - edge locations from `regions`
  - segments and `Segment=<name>` attachment policies (rule 100 × position in sorted keys) from `segments`
  - a fixed `NetworkFunctionGroup=<nfg>` rule at 1000
  - segments have `isolate_attachments = true`, so attachments in a segment learn no routes from each other
  - `segment_actions` `send-via` entries: each segment lists itself plus the segments after it in sorted order (e.g. `dev → [dev, prod]`, `prod → [prod]`). That's one per unordered pair, since send-via is bidirectional, **including same-segment pairs**. Both inter- and intra-segment traffic (e.g. prod us-east-1 ↔ prod us-west-2) therefore goes via the inspection NFG, and the GWLB appliances must allow it.
- `module "vpc"` uses `for_each = local.vpcs`. It gets `core_network_id` from the policy attachment, so VPC attachments wait for the edge locations to exist. Don't replace this with a module-level `depends_on`: that defers the module's AZ data source to apply time, and any policy edit would then force subnet replacement.

**Naming.**
- Every nameable resource is named `<name_prefix>-<type>-<context>[-<qualifier>]-<suffix>`, e.g.:
  - `bz-vpc-use1-prod-k3x9`
  - `bz-subnet-use1-inspection-gwlbe-b-k3x9`
  - `bz-sg-usw2-dev-instance-k3x9`
- The parts:
  - `name_prefix` defaults to `bz`.
  - `<suffix>` is one deployment-wide `random_string.suffix`, of length `name_suffix_length` (default 4).
  - `<context>` is `<region code>-<vpc name>`, built in `locals.tf` (`us-east-1` → `use1`).
  - The qualifier is an AZ letter or a role.
- Each module takes `name_prefix`, `name_suffix` and `name_context`, and builds names with `format(local.name_format, "<type>", "-<qualifier>")`.
- Changing the prefix or suffix length renames everything:
  - Security groups get replaced, with `create_before_destroy`.
  - EICEs are recreated. Terraform promotes them to create-before-destroy too, but EICE is limited to **1 per subnet**, so the new one fails while the old one exists.
  - Before such an apply, delete the EICEs (`aws ec2 delete-instance-connect-endpoint`) and `terraform state rm` them.
- Routes, route table associations and the policy attachment can't be named.

**`locals.tf`** flattens `regions × (segments + nfg)` into `local.vpcs`, keyed `"<region>/<name>"`. It also builds each VPC's attachment tags from the same names the policy matches on. Segment membership is tag-driven, so this shared source is what keeps attachments and policy consistent; don't hardcode tags elsewhere.

**`modules/vpc`**: one VPC, `subnet_count` (default 2) attachment subnets (`cidrsubnet(cidr, 2, i)`, one per AZ), and a Cloud WAN VPC attachment tagged with `attachment_tags`.

**Test instances (`deploy_test_instances`, default `false`):**
- When `true`, each segment VPC (not the inspection VPCs) gets:
  - a workload subnet (`cidrsubnet(cidr, 2, 2)`) and a route table sending `172.16.0.0/16` to the core network ARN (in `modules/vpc`)
  - a `modules/test_instance`: an AL2023 instance, an EC2 Instance Connect Endpoint and security groups.
- Connect with `aws ec2-instance-connect ssh --region <r> --instance-id <id> --connection-type eice`. See `ARCHITECTURE.md` §12.1 for native `ssh` (open-tunnel ProxyCommand plus `send-ssh-public-key`, 60 s key window) and ProxyJump to the us-east-1 instances.
- EICE is limited to 5 per account per region. `test_instance_eice_regions` restricts EICEs to regions with free slots (`["us-west-2"]` in the example). Instances in other regions are tested by jumping through or pinging from an instance that has one.
- Expected results (see `ARCHITECTURE.md` §12.3):
  - every instance pair passes ICMP and tcp/22, in both directions. Every pair is inspected: same-region pairs locally, cross-region pairs in us-east-1.
  - internet HTTP/HTTPS and ICMP work from all four instances
  - if a pair fails, suspect the appliance policy first. Cross-region flows are inspected only in us-east-1, so its policy must allow us-west-2 sources.

**GWLB inspection (`regions[<r>].gwlb_endpoint_service_name`, optional):**
- When set, `modules/gwlb_inspection` adds, in that region's inspection VPC:
  - one GWLB endpoint per attachment-subnet AZ, in subnets at `cidrsubnet(cidr, 2, 2..)`
  - per-AZ attachment route tables `0.0.0.0/0 → same-AZ GWLBe`
  - a GWLBe route table `0.0.0.0/0 → core network`.
- Inspection attachments have `appliance_mode_support = true` for flow symmetry.
- The service must be offered in the attachment subnets' AZs. This isn't validated in Terraform, so check with `aws ec2 describe-vpc-endpoint-services`.
- Attachment subnets use the first `subnet_count` AZ names unless pinned:
  - `regions[<r>].az_ids` pins the zone IDs for every VPC in the region. us-east-1 uses `["use1-az1", "use1-az2"]`.
  - `regions[<r>].inspection_az_ids` overrides that for the inspection VPC only.
  - Zone IDs are used because AZ names map to physical zones per account.
- Without `egress_inspection` the policy is `dual-hop`, so cross-region inter-segment traffic needs working inspection in **both** regions.

**Regional egress (`egress_inspection`, default `false`):**
- When `true` (example tfvars), the policy adds one `send-to` segment action per segment. This installs `0.0.0.0/0` in every segment pointing at the inspection NFG. There are no edge overrides, so each region egresses via its own inspection VPC.
- Workload route tables switch from `172.16.0.0/16` to `0.0.0.0/0 → core network` (`cloudwan_destination_cidr`).
- A `check` block (a plan **warning**, not an error) flags any region without `gwlb_endpoint_service_name`. That region's egress, and every cross-region pair Cloud WAN routes through it, is black-holed until endpoints exist. It's a warning so a region's endpoints can be removed while its GWLB service is swapped.
- Cloud WAN rejects one NFG used by both a dual-hop `send-via` and a `send-to` (`NETWORK_FUNCTION_GROUP_EXCLUSIVITY_VIOLATION`). So with egress enabled, `send-via` becomes **single-hop**, also without edge overrides: intra-region traffic is inspected locally, and for each cross-region pair Cloud WAN deterministically picks one of the two regions.
- `terraform apply` only prints "Incorrect policy". To see the specific errors, submit the rendered JSON with `aws networkmanager put-core-network-policy ... --cli-error-format json`.
- The GWLB appliance egresses to the internet itself, so there is no IGW or NAT in the inspection VPC.
- Set it to `false` to roll back.

**DNS conditional forwarding (`dns_forwarding`, default `null`):**
- **Input:** `{ target_ips = list(string), domain_names = map(string), system_domains = optional(map(string), {}) }`. Map keys appear in resource names.
- **Validations:**
  - `egress_inspection` must be `true`.
  - 1–6 IPv4 targets.
  - Keys match `[a-z0-9-]{1,20}`.
- **Module.** `modules/dns_forwarding` is self-contained, like `gwlb_inspection`. It creates its own subnets from the VPC CIDR. Root instantiates it with `for_each = local.dns_vpcs`, which covers every segment VPC but not the inspection VPCs. Each instance gets:
  - **Resolver subnets:** two of them, made by splitting the free 4th /26 into /27s (`cidrsubnet(cidr, 3, 6..7)`), in the attachment-subnet AZs. With this, segment VPC CIDRs are **fully used**.
  - **Route table:** `0.0.0.0/0 → core network`. The route `depends_on = [var.attachment_id]` because Cloud WAN only accepts routes from VPCs with an available attachment.
  - **Endpoint and security group:** a Route 53 Resolver OUTBOUND endpoint (Do53, one IP per resolver subnet). Its security group allows egress udp/tcp 53 to each `target_ip/32` and has no ingress.
  - **Rules:** FORWARD rules (`domain_names` → `target_ips:53`) and SYSTEM rules (`system_domains`, resolved by AWS). Each rule is associated only with its own VPC, so there are no cross-VPC associations.
- **Query path.** Queries go: endpoint ENI → core network → segment `0.0.0.0/0` (send-to) → **local** inspection VPC → same-AZ GWLBe → ZTGW → targets. No Cloud WAN policy change is involved.
- **Rule precedence.** Resolver picks the **most specific** matching rule. SYSTEM rules only matter for a subdomain of a forwarded domain, e.g. forwarding `.` but keeping `zscaler.net` on AWS.
- **`create_before_destroy`:**
  - The endpoint has none. It would propagate to the resolver subnets, whose replacements reuse the same CIDRs.
  - The security group does have it, so that renames work.
- **Quota:**
  - The limit is 4 resolver endpoints per account per region (`L-4A669CC0`, adjustable).
  - In shared accounts, check current usage and request an increase before enabling.
  - Each segment VPC (or each region, when a region is added) needs another endpoint.
- **Cost.** About $0.125 per ENI-hour, with 2 ENIs per endpoint. That's about $730 a month for 4 segment VPCs (8 ENIs).
- **Verifying.** On a test instance, run `dig <forwarded-domain>` and `dig @<target-ip> example.com`. A forwarded domain returns NXDOMAIN until it's configured on the provider side. Amazon Linux 2023 needs `sudo dnf -y install bind-utils` first. There's no Resolver query logging, so you can't see per-query evidence that a lookup went through the endpoint.

**Workload subnet AZ (`regions[<r>].workload_az_id`, optional):** a zone ID that pins the segment VPCs' workload subnet, where the test instances live. When unset it uses the first AZ name. us-east-1 uses `use1-az1`. Changing it replaces the workload subnet (same CIDR) and the instance. The same create-before-destroy caveat as below applies.

## Common changes

- **Change an existing VPC's attachment-subnet AZs (`az_ids` / `inspection_az_ids`):** this is done entirely in Terraform.
  - **Why it needs care:** the replacement subnets reuse the old CIDRs, and an attachment allows one subnet per AZ. So the old attachment and subnets must be destroyed before the new ones are created, which means the plan must show `-/+`, not `+/-`.
  - **What forces `+/-`:** `create_before_destroy` on any dependent resource propagates to its dependencies, including through module outputs. The two known sources:
    - The workload route: its `create_before_destroy` was removed for this reason.
    - The test-instance security groups (`modules/test_instance`): they keep it so renames work.
  - **Procedure:**
    1. Change `az_ids`.
    2. `terraform taint` each affected `module.vpc["<r>/<vpc>"].aws_networkmanager_vpc_attachment.this`.
    3. Temporarily set the security groups' `create_before_destroy = false`.
    4. `terraform plan`: confirm only the attachments and subnets show `-/+`.
    5. Apply. It takes ~30 min: attachment delete and create run 10–15 min each, and the timeouts are 45m.
    6. Restore `create_before_destroy = true`.
  - Don't use `terraform destroy -target` on attachments or subnets: it expands to about 50 resources across both regions through shared module outputs.
  - **With `dns_forwarding` on:** the resolver subnets follow the attachment AZs, and they reuse their CIDRs too. A resolver subnet can't be deleted while an endpoint ENI is in it. So set `dns_forwarding = null` and apply **before** the AZ change, then re-enable it afterwards. Expect about 2 minutes per endpoint.

- **Add/remove a region:** edit `regions` (unique ASN within 64512–64555, plus a CIDR for every segment and the NFG). Nothing else.
- **Add a segment:** add it to `segments` and add a CIDR for it in every region's `cidrs`. Validation enforces the CIDR keys. With `dns_forwarding` on, each new segment VPC also gets a resolver endpoint, so check the quota.
- **DNS forwarding:**
  - **Forward a domain:** add `key = "domain"` to `dns_forwarding.domain_names`. That's one rule and one association per segment VPC.
  - **Keep a subdomain on AWS:** add it to `system_domains`.
  - **Change targets:** edit `target_ips`. The rules update in place; the security group rules (keyed by IP) are added and removed.
  - **Disable:** set `dns_forwarding = null`. This destroys the endpoints, rules and resolver subnets.
  - **Disable `egress_inspection`:** set `dns_forwarding = null` first, because validation rejects the combination.

## Current gaps

- With isolated segments, **all** cross-VPC traffic depends on the GWLB appliances. If a region's inspection is broken, even same-segment traffic touching that region is dropped.
- With no edge overrides, Cloud WAN chose **us-east-1** to inspect every cross-region pair. A us-east-1 appliance outage therefore cuts all cross-region traffic.
- DNS forwarding depends on the same path: if a region's inspection breaks, forwarded lookups from that region fail.
