variable "alias" {
  description = "Alias without the alias/ prefix."
  type        = string
}

variable "description" {
  type = string
}

variable "deletion_window_days" {
  type    = number
  default = 30
}

variable "service_linked_role_arns" {
  description = "Service-linked roles allowed to use the key, e.g. AWSServiceRoleForAutoScaling for encrypted ASG volumes."
  type        = list(string)
  default     = []
}
