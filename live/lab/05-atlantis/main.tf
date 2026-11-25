# Applied LOCALLY (Atlantis cannot create or safely replace itself).
# This layer is deliberately absent from atlantis.yaml.

locals {
  name   = "${var.project}-${var.environment}"
  prefix = "/${var.project}/${var.environment}"
}

# Cross-layer inputs come from the SSM contract published by 00-bootstrap.
data "aws_ssm_parameter" "bootstrap" {
  for_each = toset([
    "state_bucket_arn",
    "state_kms_key_arn",
    "deployer_role_arn",
    "atlantis_role_name",
    "public_zone_id",
    "public_zone_name"
  ])
  name = "${local.prefix}/00-bootstrap/${each.key}"
}

module "atlantis" {
  source = "../../../modules/atlantis"

  name      = local.name
  region    = var.region
  role_name = data.aws_ssm_parameter.bootstrap["atlantis_role_name"].insecure_value

  domain_name     = "atlantis.${data.aws_ssm_parameter.bootstrap["public_zone_name"].insecure_value}"
  route53_zone_id = data.aws_ssm_parameter.bootstrap["public_zone_id"].insecure_value
  acme_email      = var.acme_email
  admin_cidrs     = var.admin_cidrs

  github_repository          = var.github_repository
  github_app_slug            = var.github_app_slug
  github_app_installation_id = var.github_app_installation_id
  github_team_allowlist      = var.github_team_allowlist
  secrets_ssm_prefix         = "${local.prefix}/atlantis"

  authorized_users   = var.authorized_users
  authorized_pr_bots = var.authorized_pr_bots
  apply_requirements = var.apply_requirements

  deployer_role_arn = data.aws_ssm_parameter.bootstrap["deployer_role_arn"].insecure_value
  state_bucket_arn  = data.aws_ssm_parameter.bootstrap["state_bucket_arn"].insecure_value
  state_kms_key_arn = data.aws_ssm_parameter.bootstrap["state_kms_key_arn"].insecure_value
}

module "outputs" {
  source = "../../../modules/ssm-outputs"
  prefix = "${local.prefix}/05-atlantis"
  values = {
    url           = module.atlantis.url
    role_arn      = module.atlantis.role_arn
    public_ip     = module.atlantis.public_ip
    instance_id   = module.atlantis.instance_id
    log_group     = module.atlantis.log_group_name
    secrets_param = "${local.prefix}/atlantis"
  }
}
