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
