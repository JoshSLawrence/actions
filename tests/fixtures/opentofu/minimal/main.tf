# No providers at all, so no lock file: exercises planning and applying a
# module without one.
terraform {
  required_version = ">= 1.9.0"
}

resource "terraform_data" "this" {
  input = "minimal"
}

output "id" {
  description = "ID of the terraform_data resource."
  value       = terraform_data.this.id
}
