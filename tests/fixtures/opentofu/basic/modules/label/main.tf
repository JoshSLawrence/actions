# A child module of basic, local to it: part of basic, so a change to it is
# a change to basic.
terraform {
  required_version = ">= 1.9.0"
}

variable "name" {
  description = "Name to label."
  type        = string
}

variable "tags" {
  description = "Tags to merge with the standard ones."
  type        = map(string)
  default     = {}
}

output "label" {
  description = "The name with its tags, including managed_by."
  value = {
    name = var.name
    tags = merge(var.tags, { managed_by = "opentofu" })
  }
}
