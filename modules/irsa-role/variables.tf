variable "name" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "issuer_host" {
  description = "Issuer URL without https:// (prefix of the :sub/:aud condition keys)."
  type        = string
}

variable "namespace" {
  type = string
}

variable "service_account" {
  type = string
}

variable "policy_json" {
  type    = string
  default = null
}

variable "managed_policy_arns" {
  type    = list(string)
  default = []
}
