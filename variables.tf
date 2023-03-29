variable "aviatrix_account_name" {
  description = "AWS account name on the Aviatrix Controller."
  type        = string
}

variable "region_name_prefix" {
  description = "String to prepend to resources. No hypens allowed."
  type        = string

  validation {
    condition     = length(regexall("-", var.region_name_prefix)) == 0
    error_message = "region_name_prefix cannot contain hypens."
  }
}

variable "other_uses_cidr" {
  description = "CIDR for transit gateway."
  type        = string

  validation {
    condition     = split("/", var.other_uses_cidr)[1] == "22"
    error_message = "This module needs a /22."
  }
}

variable "avx_asn" {
  description = "ASN for Aviatrix Transit Gateway"
  type        = number

  validation {
    condition     = var.avx_asn >= 64512 && var.avx_asn <= 65534
    error_message = "ASN must be between 64512 and 65534."
  }
}

variable "tgw_id" {
  description = "Transit Gateway ID"
  type        = string
}

variable "tgw_attachment_ids" {
  description = "IDs of Transit Gateway Workload attachments."
  type        = list(string)
}

locals {
  transit_cidr = cidrsubnet(var.other_uses_cidr, 1, 0)
}