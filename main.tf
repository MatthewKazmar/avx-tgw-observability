# Deploy Aviatrix Transit and bump in the wire on a AWS TGW.
data "aws_region" "current" {}

data "aws_ec2_transit_gateway" "this" {
  id = var.tgw_id
}

module "transit" {
  source  = "terraform-aviatrix-modules/mc-transit/aviatrix"
  version = "2.4.1"

  cloud           = "aws"
  region          = data.aws_region.current.name
  cidr            = local.transit_cidr
  local_as_number = var.avx_asn
  account         = var.aviatrix_account_name
}

# Create TGW subnets, attachments, and TGW Connect routes.
resource "aws_subnet" "this" {
  for_each = { for i in [0, 1] :
    "${var.region_name_prefix}-tgw-${i + 1}" => {
      cidr_block = cidrsubnet(local.transit_cidr, 5, 14 + i)
      az         = distinct([for v in module.transit.vpc.subnets : regex("[a-z]{2}-[a-z]*-[0-9][a-z]", v.name)])[i]
    }
  }

  vpc_id            = module.transit.vpc.vpc_id
  cidr_block        = each.value.cidr_block
  availability_zone = each.value.az

  tags = {
    Name = each.key
  }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  subnet_ids                                      = [for k, v in aws_subnet.this : v.id]
  vpc_id                                          = module.transit.vpc.vpc_id
  transit_gateway_id                              = var.tgw_id
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = {
    Name = "${var.region_name_prefix}-avx-vpc"
  }
}

resource "aws_ec2_transit_gateway_connect" "this" {
  transport_attachment_id                         = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_id                              = var.tgw_id
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = {
    Name = "${var.region_name_prefix}-avx-connect"
  }
}

data "aws_route_tables" "this" {
  vpc_id = module.transit.vpc.vpc_id
  filter {
    name   = "tag:${module.transit.vpc.name}"
    values = ["Public-rtb"]
  }
}

resource "aws_route" "route_tgw_connect" {
  route_table_id         = data.aws_route_tables.this.ids[0]
  destination_cidr_block = data.aws_ec2_transit_gateway.this.transit_gateway_cidr_blocks[0]
  transit_gateway_id     = var.tgw_id
}

# Create Avx TGW route table and associate it with the attachments.
resource "aws_ec2_transit_gateway_route_table" "avx" {
  transit_gateway_id = var.tgw_id

  tags = {
    Name = "${var.region_name_prefix}-avx-transit"
  }
}

resource "aws_ec2_transit_gateway_route_table_association" "avx_vpc" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.avx.id
}

resource "aws_ec2_transit_gateway_route_table_association" "avx_connect" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_connect.this.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.avx.id
}

# Create TGW Connect Peers and Aviatrix GRE tunnel.
resource "aws_ec2_transit_gateway_connect_peer" "primary" {
  peer_address                  = module.transit.transit_gateway.private_ip
  bgp_asn                       = var.avx_asn
  transit_gateway_address       = cidrhost(data.aws_ec2_transit_gateway.this.transit_gateway_cidr_blocks[0], 1)
  inside_cidr_blocks            = ["169.254.100.0/29"]
  transit_gateway_attachment_id = aws_ec2_transit_gateway_connect.this.id
}

resource "aws_ec2_transit_gateway_connect_peer" "ha" {
  peer_address                  = module.transit.transit_gateway.ha_private_ip
  bgp_asn                       = var.avx_asn
  transit_gateway_address       = cidrhost(data.aws_ec2_transit_gateway.this.transit_gateway_cidr_blocks[0], 2)
  inside_cidr_blocks            = ["169.254.100.8/29"]
  transit_gateway_attachment_id = aws_ec2_transit_gateway_connect.this.id
}

resource "aviatrix_transit_external_device_conn" "this" {
  vpc_id            = module.transit.vpc.vpc_id
  connection_name   = "${var.region_name_prefix}-to-tgw"
  gw_name           = module.transit.transit_gateway.gw_name
  connection_type   = "bgp"
  tunnel_protocol   = "GRE"
  bgp_local_as_num  = var.avx_asn
  bgp_remote_as_num = data.aws_ec2_transit_gateway.this.amazon_side_asn

  remote_gateway_ip  = aws_ec2_transit_gateway_connect_peer.primary.transit_gateway_address
  local_tunnel_cidr  = "169.254.100.1/29,169.254.100.17/29"
  remote_tunnel_cidr = "169.254.100.2/29,169.254.100.18/29"

  ha_enabled                = true
  backup_remote_gateway_ip  = aws_ec2_transit_gateway_connect_peer.ha.transit_gateway_address
  backup_local_tunnel_cidr  = "169.254.100.25/29,169.254.100.9/29"
  backup_remote_tunnel_cidr = "169.254.100.26/29,169.254.100.10/29"
  backup_bgp_remote_as_num  = data.aws_ec2_transit_gateway.this.amazon_side_asn

  manual_bgp_advertised_cidrs = ["10.0.0.0/8"]
}

# Get existing attachments for propagation.
# data "aws_ec2_transit_gateway_vpc_attachments" "this" {
#   filter {
#     name   = "transit-gateway-id"
#     values = [var.tgw_id]
#   }
# }

# Create new route table for the workload attachments and associate them.
resource "aws_ec2_transit_gateway_route_table" "workload" {
  transit_gateway_id = var.tgw_id

  tags = {
    Name = "${var.region_name_prefix}-avx-workload"
  }
}

resource "null_resource" "disassociate_default_tgw_rtb" {
  #for_each = toset([for v in data.aws_ec2_transit_gateway_vpc_attachments.this.ids : v if v != aws_ec2_transit_gateway_vpc_attachment.this.id])
  for_each = toset([for v in var.tgw_attachment_ids : v if v != aws_ec2_transit_gateway_vpc_attachment.this.id])

  provisioner "local-exec" {
    command = "aws ec2 disassociate-transit-gateway-route-table --transit-gateway-route-table-id ${data.aws_ec2_transit_gateway.this.association_default_route_table_id} --transit-gateway-attachment-id ${each.value} --region ${data.aws_region.current.name};sleep 90"
  }
}

resource "aws_ec2_transit_gateway_route_table_association" "workload" {
  #for_each                       = toset([for v in data.aws_ec2_transit_gateway_vpc_attachments.this.ids : v if v != aws_ec2_transit_gateway_vpc_attachment.this.id])
  for_each                       = toset([for v in var.tgw_attachment_ids : v if v != aws_ec2_transit_gateway_vpc_attachment.this.id])
  transit_gateway_attachment_id  = each.value
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.workload.id

  depends_on = [
    null_resource.disassociate_default_tgw_rtb
  ]
}

# Propagate VPC prefixes to the Aviatrix Route Table.
resource "aws_ec2_transit_gateway_route_table_propagation" "avx" {
  for_each = toset([for v in data.aws_ec2_transit_gateway_vpc_attachments.this.ids : v if v != aws_ec2_transit_gateway_vpc_attachment.this.id])

  transit_gateway_attachment_id  = each.value
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.avx.id
}

# Propagate Aviatrix TGW Connect prefixes to workload Route Table.
resource "aws_ec2_transit_gateway_route_table_propagation" "workload" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_connect.this.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.workload.id
}