variable aviatrix_account_name {
  description = "AWS account name on the Aviatrix Controller."
  type = string
}

variable "region_name_prefix" {
  description = "String to prepend to resources. No hypens allowed."
  type        = string

  validation {
    condition     = length(regexall("-", var.region_name_prefix)) == 0
    error_message = "region_name_prefix cannot contain hypens."
  }
}

variable other_uses_cidr {
  description = "CIDR for transit gateway."
  type = string

  validation {
    condition     = split("/", var.transit_cidr)[1] == "22"
    error_message = "This module needs a /22."
  }
}

variable tgw_id {
  description = "Transit Gateway ID"
  type = string
}

locals {
  transit_cidr = cidrsubnet(var.other_uses_cidr, 1, 0)
}