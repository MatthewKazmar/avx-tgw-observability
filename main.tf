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
  for_each = { for i in range(0, 1) :
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
  subnet_ids         = [for k, v in aws_subnet.this : v.id]
  vpc_id             = module.transit.vpc.vpc_id
  transit_gateway_id = var.tgw_id
}

resource "aws_ec2_transit_gateway_connect" "this" {
  transport_attachment_id = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_id      = var.tgw_id
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

  remote_gateway_ip        = aws_ec2_transit_gateway_connect_peer.primary.transit_gateway_address
  local_tunnel_cidr  = "169.254.100.1/30,169.254.100.9/30"
  remote_tunnel_cidr = "169.254.100.2/30,169.254.100.10/30"

  ha_enabled                = true
  backup_remote_gateway_ip = aws_ec2_transit_gateway_connect_peer.ha.transit_gateway_address
  backup_local_tunnel_cidr  = "169.254.100.5/30,169.254.100.13/30"
  backup_remote_tunnel_cidr = "169.254.100.6/30,169.254.100.14/30"
  backup_bgp_remote_as_num  = data.aws_ec2_transit_gateway.this.amazon_side_asn
}