terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

locals {
  github_oidc_host = "token.actions.githubusercontent.com"
  provider_arn     = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.existing_oidc_provider_arn
}

# One per account. Set create_oidc_provider = false if another stack owns it.
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_oidc_provider ? 1 : 0
  url            = "https://${local.github_oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # e.g. repo:org/repo:environment:ami-build  or  repo:org/repo:ref:refs/heads/main
    # Never use a wildcard on the repository part.
    condition {
      test     = "StringLike"
      variable = "${local.github_oidc_host}:sub"
      values   = var.subjects
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = var.role_name
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = var.max_session_duration
}

resource "aws_iam_role_policy" "inline" {
  count  = var.policy_json == null ? 0 : 1
  name   = "${var.role_name}-inline"
  role   = aws_iam_role.this.id
  policy = var.policy_json
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each   = toset(var.managed_policy_arns)
  role       = aws_iam_role.this.name
  policy_arn = each.value
}
