# Nested inside the minimal root module, with one deployment,
# deployments/sandbox.yaml (and its sandbox.tfvars).
terraform {
  required_version = ">= 1.9.0"
}

variable "label" {
  description = "Recorded by the terraform_data resource; set per deployment."
  type        = string
}

resource "terraform_data" "this" {
  input = var.label
}

output "id" {
  description = "ID of the terraform_data resource."
  value       = terraform_data.this.id
}
