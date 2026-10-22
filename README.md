# terraform-aws-cwan-modules

Terraform for a multi-region **AWS Cloud WAN** core network where every flow is inspected by a regional **Gateway Load Balancer (GWLB)** security service:
- traffic between segments
- traffic within a segment
- internet egress
- optionally, conditional DNS forwarding.

The design rationale, routing tables and traffic flows are in [`ARCHITECTURE.md`](ARCHITECTURE.md).

## What it builds

```
                 Cloud WAN core network (global)
   ┌───────────── edge us-east-1 ─────────────┐  ┌───────────── edge us-west-2 ─────────────┐
   │ prod seg   dev seg   inspection NFG      │◄─►│ prod seg   dev seg   inspection NFG      │
   └────┬─────────┬────────────┬──────────────┘  └────┬─────────┬────────────┬──────────────┘
     prod VPC  dev VPC   inspection VPC               prod VPC  dev VPC   inspection VPC
                          │ GWLB endpoints (per AZ)                        │ GWLB endpoints
                          ▼                                                ▼
                 security service → internet / DNS               security service → internet / DNS
```

- **Core network:** a global network and a core network with one edge per region, built from a generated policy document.
- **Segments:** `prod` and `dev` by default, with `isolate-attachments = true`, so VPCs in a segment never route to each other directly.
- **Inspection NFG:** one inspection VPC per region, with GWLB endpoints in two AZs pointing to a third-party endpoint service.
- **Service insertion:**
  - `send-via` (single-hop) covers every pair of segments, same-segment pairs included, so all VPC-to-VPC traffic crosses one appliance.
  - `send-to` installs a default route in every segment, so each region egresses through its **own** inspection VPC.
- **No internet edge in the VPCs:** no IGW, NAT gateway or public IP. The security service owns egress.
- **Optional DNS conditional forwarding:** a Route 53 Resolver outbound endpoint in each segment VPC forwards selected domains to the provider's DNS servers, through the local inspection VPC.
- **Optional test instances:** an Amazon Linux 2023 instance in each segment VPC, reached through EC2 Instance Connect Endpoints, with an optional endpoint agent installed by user data.

## Requirements

- Terraform **>= 1.9** (cross-variable validation).
- AWS provider **~> 6.0**. It uses one provider with no aliases, and regional resources set the `region` argument themselves.
- A GWLB endpoint service in each region (e.g. from your security vendor), offered in the AZs you pin with `az_ids`.
- IAM permissions for Network Manager, EC2/VPC, Route 53 Resolver and EC2 Instance Connect.

## Quick start

```sh
cp terraform.tfvars.example terraform.tfvars    # gitignored; fill in real values
export TF_VAR_zscaler_provision_key='...'       # only if deploying test instances with the agent

terraform init
terraform plan
terraform apply
```

`terraform.tfvars` is loaded automatically. Creating a VPC attachment takes 10–15 minutes, and a first apply takes roughly 30–45 minutes.

## Inputs

| Variable | Default | Purpose |
|---|---|---|
| `aws_profile` | `null` | AWS CLI profile. `null` uses the default credential chain. |
| `home_region` | `us-east-1` | Provider default region |
| `regions` | two regions | `region => { asn, cidrs = { <segment>/<nfg> = cidr }, gwlb_endpoint_service_name?, az_ids?, inspection_az_ids?, workload_az_id? }` |
| `segments` | `prod`, `dev` | `name => description` |
| `inspection_nfg_name` | `inspection` | Name of the Network Function Group and its VPCs |
| `egress_inspection` | `false` | Regional internet egress through inspection (`send-to`). Also makes `send-via` single-hop. |
| `dns_forwarding` | `null` | `{ target_ips, domain_names, system_domains? }`. Needs `egress_inspection = true`. |
| `deploy_test_instances` | `false` | Test instance, workload subnet and EICE in each segment VPC |
| `test_instance_type` | `t3.micro` | Test instance size |
| `test_instance_eice_regions` | `null` (all) | Regions that get an EC2 Instance Connect Endpoint (limit: 5 per region) |
| `zscaler_provision_key` | `null` (sensitive) | Agent provision key for test-instance user data |
| `name_prefix` / `name_suffix_length` | `bz` / `4` | Resource naming: `<prefix>-<type>-<region>-<vpc>[-<qualifier>]-<suffix>` |

Validation checks:
- each region's ASN is in `64512–64555`
- every segment and the NFG have a CIDR in every region
- the DNS forwarding inputs (1–6 IPv4 targets, safe keys, and `egress_inspection` enabled).

A plan-time `check` warns when `egress_inspection` is on but a region has no GWLB service.

## Outputs

| Output | Contents |
|---|---|
| `global_network_id`, `core_network_id`, `core_network_arn` | Core network identifiers |
| `vpcs` | VPC IDs, subnet IDs and attachment IDs, keyed `"<region>/<name>"` |
| `gwlb_endpoints` | GWLB endpoint and subnet IDs per inspection VPC |
| `test_instances` | Instance ID, private IP and EICE ID per segment VPC |
| `dns_forwarding` | Resolver endpoint ID, IPs and rule IDs per segment VPC |

## Layout

```
├── main.tf / locals.tf / variables.tf / outputs.tf / version.tf
└── modules/
    ├── vpc/              VPC, attachment subnets, Cloud WAN attachment, optional workload subnet
    ├── gwlb_inspection/  GWLB endpoints and per-AZ routing in inspection VPCs
    ├── dns_forwarding/   Route 53 Resolver outbound endpoint, rules and resolver subnets
    └── test_instance/    AL2023 test instance, security groups, optional EICE
```

Every VPC `/24` is split into four `/26`s:
- **Segment VPCs:** two attachment subnets, a workload subnet, and two resolver `/27`s.
- **Inspection VPCs:** two attachment subnets and two GWLB endpoint subnets.

## Testing connectivity

With `deploy_test_instances = true`, connect through EC2 Instance Connect:

```sh
aws ec2-instance-connect ssh --region <region> --instance-id <id> --connection-type eice
```

The test procedure and expected results are in `ARCHITECTURE.md` §12. It covers ICMP and SSH between every pair of instances, plus HTTP(S), ICMP and DNS to the internet. Every pair is inspected, so the appliances must allow the flows you test.

## Secrets and private data

- **Never commit real values.** `terraform.tfvars`, `*.auto.tfvars`, `.env`, all Terraform state, `private/` and `CLAUDE.local.md` are gitignored.
- **The example file holds placeholders only.** `terraform.tfvars.example` uses documentation IDs and IPs such as `198.51.100.0/24` and `corp.example.com`.
- **Provision key exposure.** Pass it with `TF_VAR_zscaler_provision_key`. It still ends up in instance user data and in state, so use an encrypted remote backend (e.g. S3 with locking) beyond a lab.

## Operational notes

- **Changing an existing VPC's AZs** replaces its Cloud WAN attachment, because the new subnets reuse the old CIDRs. Follow the procedure in [`CLAUDE.md`](CLAUDE.md) under "Common changes". Never use `terraform destroy -target` on attachments or subnets.
- **Renaming** (`name_prefix` / `name_suffix_length`) needs the EICEs deleted first, because only one is allowed per subnet.
- **Policy errors.** `terraform apply` reports only "Incorrect policy". Submit the rendered JSON with `aws networkmanager put-core-network-policy --cli-error-format json` to see the details.
- **Quotas:** 5 EICEs per region, and 4 Route 53 Resolver endpoints per region by default (DNS forwarding uses one per segment VPC).
