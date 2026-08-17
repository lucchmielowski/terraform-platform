variable "name_prefix" {
  description = "Prefix for resource names (lowercase alphanumeric only, storage account naming is the binding constraint)"
  type        = string
  default     = "tfplatform"
}

variable "location" {
  description = "Azure region for the mock resources"
  type        = string
  default     = "westeurope"
}
