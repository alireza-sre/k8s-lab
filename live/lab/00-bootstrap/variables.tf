variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "region" {
  type = string
}

variable "public_hostname" {
  type = string
}

variable "github_repository" {
  description = "owner/name of the infrastructure repository."
  type        = string
}

variable "github_oidc_subject_prefix" {
  description = <<-EOT
    Immutable OIDC subject prefix of github_repository, as GitHub puts it in the
    token's sub claim: repo:<owner>@<owner_id>/<repo>@<repo_id>. Numeric IDs are
    never reused, so a renamed/deleted repo re-registered by someone else can't
    assume the role. Get it with:
      gh api repos/<owner>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix
  EOT
  type        = string

  validation {
    condition     = can(regex("^repo:[^@/:*]+@[0-9]+/[^@/:*]+@[0-9]+$", var.github_oidc_subject_prefix))
    error_message = "Expected the immutable form repo:<owner>@<owner_id>/<repo>@<repo_id>."
  }

  validation {
    condition     = replace(var.github_oidc_subject_prefix, "/@[0-9]+/", "") == "repo:${var.github_repository}"
    error_message = "github_oidc_subject_prefix must belong to github_repository (same owner/repo names)."
  }
}

variable "deployer_role_arn" {
  description = "Declared because common.tfvars sets it for every layer. Not used here: this layer creates the role."
  type        = string
  default     = null
}

variable "admin_principal_arns" {
  description = <<-EOT
    IAM principal ARNs (patterns allowed) that may assume the deployer role from
    a workstation, e.g. for applying 05-atlantis or break-glass.
    For IAM Identity Center use the role ARN, e.g.
    arn:aws:iam::123456789012:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_AdministratorAccess_*
  EOT
  type        = list(string)
}

variable "create_autoscaling_service_linked_role" {
  description = "Create AWSServiceRoleForAutoScaling. Set false if the account already has it (any ASG ever created)."
  type        = bool
  default     = false
}
