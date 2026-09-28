# Local state, so CI needs no cloud account. Each deployment picks its own
# state file through deployments/<name>.tfbackend -- the same way a real
# module would set a per-deployment key for an azurerm backend.
terraform {
  backend "local" {}
}
