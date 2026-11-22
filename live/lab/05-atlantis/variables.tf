# --- common (../common.tfvars) ---
variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "region" {
  type = string
}

variable "deployer_role_arn" {
  type = string
}

variable "github_repository" {
  type = string
}

# --- layer ---
variable "acme_email" {
  type = string
}

variable "admin_cidrs" {
  description = "Your office/VPN egress CIDRs for the Atlantis UI."
  type        = list(string)
  default     = []
}

variable "github_app_slug" {
  type = string
}

variable "github_app_installation_id" {
  type    = string
  default = ""
}

variable "github_team_allowlist" {
  type    = string
  default = ""
}
