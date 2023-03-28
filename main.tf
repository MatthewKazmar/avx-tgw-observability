# Deploy Aviatrix Transit and bump in the wire on a AWS TGW.
data "aws_region" "current" {}

module "transit" {
  source  = "terraform-aviatrix-modules/mc-transit/aviatrix"
  version = "2.4.1"

  cloud   = "aws"
  region  = data.aws_region.current.name
  cidr    = local.transit_cidr
  account = var.aviatrix_account_name
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

# resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
#   subnet_ids         = aws_subnet.this[*].id
#   vpc_id             = module.transit.vpc.vpc_id
#   transit_gateway_id = var.tgw_id
# }
