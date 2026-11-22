variable "role_name" {
  type = string
}

variable "subjects" {
  description = "Allowed GitHub OIDC 'sub' claims, e.g. [\"repo:org/repo:environment:ami-build\"]."
  type        = list(string)

  validation {
    condition     = alltrue([for s in var.subjects : can(regex("^repo:[^*/]+/[^*/:]+:", s))])
    error_message = "Each subject must pin an explicit owner/repo (no wildcards before the first ':')."
  }
}

variable "create_oidc_provider" {
  type    = bool
  default = true
}

variable "existing_oidc_provider_arn" {
  type    = string
  default = null
}

variable "policy_json" {
  type    = string
  default = null
}

variable "managed_policy_arns" {
  type    = list(string)
  default = []
}

variable "max_session_duration" {
  type    = number
  default = 3600
}
