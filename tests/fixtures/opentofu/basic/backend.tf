# Local state, so CI needs no cloud account. Each deployment picks its own
# state file through var.state_path (in its .tfvars, or TF_VAR_state_path) --
# OpenTofu evaluates variables in the backend block -- the same way a real
# module sets a per-deployment key for an azurerm backend.
terraform {
  backend "local" {
    path = var.state_path
  }
}
