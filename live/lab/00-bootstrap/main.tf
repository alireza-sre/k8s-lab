locals {
  name   = "${var.project}-${var.environment}"
  layer  = "00-bootstrap"
  prefix = "/${var.project}/${var.environment}"

  tags = {
    Project     = var.project
    Environment = var.environment
    Layer       = local.layer
    ManagedBy   = "terraform"
    Repository  = var.github_repository
  }

  # Role name the 05-atlantis layer will create. Referenced by pattern so this
  # layer does not depend on it existing (IAM rejects unknown principals in
  # trust policies, but not in conditions).
  atlantis_role_name = "${local.name}-atlantis"

  # Bootstrapping user, gets access to terraform-deployer role
  bootstrap_admin = data.aws_caller_identity.current.arn
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# ---------------------------------------------------------------------------
# Remote state
# ---------------------------------------------------------------------------
module "state_backend" {
  source = "../../../modules/state-backend"
  name   = local.name
}

# ---------------------------------------------------------------------------
# DNS
# ---------------------------------------------------------------------------
resource "aws_route53_zone" "public" {
  name = var.public_hostname
  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Deployer role: the only identity that changes infrastructure from layer 05
# onwards. Atlantis assumes it; humans assume it only for break-glass and for
# the Atlantis layer itself. State access is granted separately, to the
# caller's own identity, so "can read state" and "can change infra" stay
# distinct permissions.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "deployer_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values = concat(
        [
          "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.atlantis_role_name}",
          local.bootstrap_admin
        ],
        var.admin_principal_arns,
      )
    }
  }
}

resource "aws_iam_role" "deployer" {
  name                 = "${local.name}-terraform-deployer"
  description          = "Applies Terraform layers 05+ for ${local.name}"
  assume_role_policy   = data.aws_iam_policy_document.deployer_trust.json
  max_session_duration = 3600
}

# Lab default: broad rights. To harden, replace with per-layer roles whose
# policies list only the services each layer touches.
resource "aws_iam_role_policy_attachment" "deployer_admin" {
  role       = aws_iam_role.deployer.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AdministratorAccess"
}

# Guardrails that hold even with AdministratorAccess: the deployer can never
# weaken its own trust, delete state, or schedule deletion of the state key.
data "aws_iam_policy_document" "deployer_guardrails" {
  statement {
    sid    = "ProtectStateBucket"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket",
      "s3:DeleteBucketPolicy",
      "s3:PutBucketPolicy",
      "s3:PutBucketVersioning",
      "s3:PutEncryptionConfiguration",
      "s3:PutLifecycleConfiguration",
      "s3:DeleteObjectVersion",
    ]
    resources = [module.state_backend.bucket_arn, "${module.state_backend.bucket_arn}/*"]
  }

  statement {
    sid       = "ProtectStateKey"
    effect    = "Deny"
    actions   = ["kms:ScheduleKeyDeletion", "kms:DisableKey", "kms:PutKeyPolicy"]
    resources = [module.state_backend.kms_key_arn]
  }

  statement {
    sid    = "ProtectSelf"
    effect = "Deny"
    actions = [
      "iam:UpdateAssumeRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:DeleteRole",
    ]
    resources = [aws_iam_role.deployer.arn]
  }
}

resource "aws_iam_role_policy" "deployer_guardrails" {
  name   = "guardrails"
  role   = aws_iam_role.deployer.id
  policy = data.aws_iam_policy_document.deployer_guardrails.json
}

# ---------------------------------------------------------------------------
# GitHub Actions role for the weekly Packer AMI build. Only workflows running
# in the "ami-build" environment of this repository can assume it.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "packer" {
  statement {
    sid    = "PackerAmazonEbs"
    effect = "Allow"
    actions = [
      "ec2:AttachVolume",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:CopyImage",
      "ec2:CreateImage",
      "ec2:CreateKeyPair",
      "ec2:CreateSecurityGroup",
      "ec2:CreateSnapshot",
      "ec2:CreateTags",
      "ec2:CreateVolume",
      "ec2:DeleteKeyPair",
      "ec2:DeleteSecurityGroup",
      "ec2:DeleteSnapshot",
      "ec2:DeleteVolume",
      "ec2:DeregisterImage",
      "ec2:Describe*",
      "ec2:DetachVolume",
      "ec2:GetPasswordData",
      "ec2:ModifyImageAttribute",
      "ec2:ModifyInstanceAttribute",
      "ec2:ModifySnapshotAttribute",
      "ec2:RegisterImage",
      "ec2:RunInstances",
      "ec2:StopInstances",
      "ec2:TerminateInstances",
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = ["*"]
  }
}

module "github_packer_role" {
  source = "../../../modules/github-oidc-role"

  role_name   = "${local.name}-github-packer"
  subjects    = ["repo:${var.github_repository}:environment:ami-build"]
  policy_json = data.aws_iam_policy_document.packer.json
}

# EBS volumes encrypted with a customer-managed key can only be launched by an
# ASG when the key policy names this role (see 20-identity). Every account
# that has ever used Auto Scaling already has it.
resource "aws_iam_service_linked_role" "autoscaling" {
  count            = var.create_autoscaling_service_linked_role ? 1 : 0
  aws_service_name = "autoscaling.amazonaws.com"
}

# ---------------------------------------------------------------------------
# Cross-layer contract
# ---------------------------------------------------------------------------
module "outputs" {
  source = "../../../modules/ssm-outputs"
  prefix = "${local.prefix}/${local.layer}"
  values = {
    state_bucket_name    = module.state_backend.bucket_name
    state_bucket_arn     = module.state_backend.bucket_arn
    state_kms_key_arn    = module.state_backend.kms_key_arn
    deployer_role_arn    = aws_iam_role.deployer.arn
    atlantis_role_name   = local.atlantis_role_name
    github_oidc_provider = module.github_packer_role.oidc_provider_arn
    public_zone_id       = aws_route53_zone.public.zone_id
    public_zone_name     = trimsuffix(aws_route53_zone.public.name, ".")
  }
}
