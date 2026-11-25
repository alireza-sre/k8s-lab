variable "name" {
  description = "Name prefix, e.g. kube-ec2-lab."
  type        = string
}

variable "region" {
  type = string
}

variable "role_name" {
  description = "IAM role name for the instance; must match what 00-bootstrap trusts."
  type        = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.255.255.0/24"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "root_volume_size_gb" {
  type    = number
  default = 30
}

variable "domain_name" {
  description = "FQDN for Atlantis, e.g. atlantis.example.com. Must be in route53_zone_id."
  type        = string
}

variable "route53_zone_id" {
  description = "Public hosted zone that holds domain_name."
  type        = string
}

variable "acme_email" {
  description = "Contact email for Let's Encrypt certificates."
  type        = string
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach the Atlantis UI (in addition to GitHub's webhook ranges)."
  type        = list(string)
  default     = []
}

variable "github_repository" {
  description = "owner/name; the only repository this Atlantis will act on."
  type        = string
}

variable "github_app_slug" {
  description = "Slug of the GitHub App (the URL name), used for comment attribution."
  type        = string
}

variable "github_app_installation_id" {
  description = "Optional installation ID of the GitHub App. Leave empty to let Atlantis discover it."
  type        = string
  default     = ""
}

variable "github_team_allowlist" {
  description = "Optional ATLANTIS_GH_TEAM_ALLOWLIST, e.g. \"platform:plan,platform:apply,*:plan\". Requires the Members permission."
  type        = string
  default     = ""
}

variable "authorized_users" {
  description = "GitHub logins allowed to apply, and to plan with extra arguments. Changes take effect within a minute, without replacing the instance."
  type        = list(string)

  validation {
    condition     = length(var.authorized_users) > 0 && alltrue([for u in var.authorized_users : can(regex("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$", u))])
    error_message = "Give at least one GitHub login (letters, digits, hyphens)."
  }
}

variable "authorized_pr_bots" {
  description = "Bot logins whose PRs may be planned (never applied), e.g. [\"kube-ec2-bot[bot]\"]."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for b in var.authorized_pr_bots : can(regex("^[A-Za-z0-9-]+\\[bot\\]$", b))])
    error_message = "Bot logins look like <app-slug>[bot]."
  }
}

variable "apply_requirements" {
  description = "Atlantis apply/import requirements. Add \"approved\" once someone other than the PR author reviews."
  type        = list(string)
  default     = ["mergeable", "undiverged"]

  validation {
    condition     = alltrue([for r in var.apply_requirements : contains(["approved", "mergeable", "undiverged"], r)])
    error_message = "Allowed values: approved, mergeable, undiverged."
  }
}

variable "secrets_ssm_prefix" {
  description = "SSM path holding github-app-id, github-app-key, github-webhook-secret, web-password."
  type        = string
}

variable "atlantis_image" {
  type    = string
  default = "ghcr.io/runatlantis/atlantis:v0.49.0"
}

variable "caddy_image" {
  type    = string
  default = "caddy:2"
}

variable "terraform_version" {
  description = "Default Terraform version Atlantis downloads and uses."
  type        = string
  default     = "1.17.1"
}

variable "deployer_role_arn" {
  type = string
}

variable "state_bucket_arn" {
  type = string
}

variable "state_kms_key_arn" {
  type = string
}

variable "log_retention_days" {
  type    = number
  default = 90
}
