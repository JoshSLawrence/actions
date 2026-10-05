# A child module of basic, local to it. It has no mise.toml, so discovery
# doesn't treat it as a root module of its own.
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
