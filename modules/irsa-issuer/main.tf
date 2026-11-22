# IAM Roles for Service Accounts on a self-managed cluster.
#
# AWS STS must be able to fetch the cluster's OIDC discovery document and
# signing keys over public HTTPS. EKS hosts these for you; here they live in
# a dedicated S3 bucket with exactly two publicly readable objects:
#
#   <issuer>/.well-known/openid-configuration
#   <issuer>/openid/v1/jwks
#
# The kube-apiserver is started with --service-account-issuer=<issuer> and
# --service-account-jwks-uri=<issuer>/openid/v1/jwks, and the first control
# plane node uploads both documents (kubectl get --raw ...) after kubeadm init.
#
# Note: if your account enforces S3 Block Public Access at the ACCOUNT level,
# this bucket cannot be public. Front it with CloudFront + OAC instead and use
# the CloudFront domain as the issuer.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  bucket_name = "${var.name}-oidc-${data.aws_caller_identity.current.account_id}"
  issuer_host = "${local.bucket_name}.s3.${data.aws_region.current.region}.amazonaws.com"
  issuer_url  = "https://${local.issuer_host}"
  public_keys = [".well-known/openid-configuration", "openid/v1/jwks"]
}

resource "aws_s3_bucket" "oidc" {
  bucket        = local.bucket_name
  force_destroy = true # only holds re-publishable public documents
}

resource "aws_s3_bucket_ownership_controls" "oidc" {
  bucket = aws_s3_bucket.oidc.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# ACLs stay blocked; only the bucket policy below grants public read.
resource "aws_s3_bucket_public_access_block" "oidc" {
  bucket                  = aws_s3_bucket.oidc.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_server_side_encryption_configuration" "oidc" {
  bucket = aws_s3_bucket.oidc.id
  rule {
    # Anonymous readers cannot use KMS keys, so SSE-S3 it is.
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "oidc" {
  bucket = aws_s3_bucket.oidc.id
  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_iam_policy_document" "oidc" {
  statement {
    sid       = "PublicReadDiscoveryDocsOnly"
    actions   = ["s3:GetObject"]
    resources = [for k in local.public_keys : "${aws_s3_bucket.oidc.arn}/${k}"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.oidc.arn, "${aws_s3_bucket.oidc.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "oidc" {
  bucket     = aws_s3_bucket.oidc.id
  policy     = data.aws_iam_policy_document.oidc.json
  depends_on = [aws_s3_bucket_public_access_block.oidc]
}

data "tls_certificate" "issuer" {
  url = local.issuer_url
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = local.issuer_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.issuer.certificates[length(data.tls_certificate.issuer.certificates) - 1].sha1_fingerprint]
}
