terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_iam_policy_document" "key" {
  # Delegate access control to IAM policies in this account (standard default).
  statement {
    sid       = "AccountRootAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  # Service-linked roles (e.g. Auto Scaling) cannot be granted KMS rights via
  # IAM, so they must be named in the key policy to launch encrypted volumes.
  dynamic "statement" {
    for_each = length(var.service_linked_role_arns) > 0 ? [1] : []
    content {
      sid       = "ServiceLinkedRoleUse"
      actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
      resources = ["*"]
      principals {
        type        = "AWS"
        identifiers = var.service_linked_role_arns
      }
    }
  }

  dynamic "statement" {
    for_each = length(var.service_linked_role_arns) > 0 ? [1] : []
    content {
      sid       = "ServiceLinkedRoleGrants"
      actions   = ["kms:CreateGrant"]
      resources = ["*"]
      principals {
        type        = "AWS"
        identifiers = var.service_linked_role_arns
      }
      condition {
        test     = "Bool"
        variable = "kms:GrantIsForAWSResource"
        values   = ["true"]
      }
    }
  }
}

resource "aws_kms_key" "this" {
  description             = var.description
  enable_key_rotation     = true
  deletion_window_in_days = var.deletion_window_days
  policy                  = data.aws_iam_policy_document.key.json
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.alias}"
  target_key_id = aws_kms_key.this.key_id
}
