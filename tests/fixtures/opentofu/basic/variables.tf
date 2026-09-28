variable "name_prefix" {
  description = "Prefix for the generated name. Lowercase letters and digits, starting with a letter."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,9}$", var.name_prefix))
    error_message = "name_prefix must be 2-10 lowercase letters or digits, starting with a letter."
  }
}

variable "tags" {
  description = "Tags recorded alongside the generated name."
  type        = map(string)
  default     = {}
}
