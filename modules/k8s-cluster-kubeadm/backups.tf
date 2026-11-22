# etcd snapshots, uploaded hourly by every control-plane node
# (k8s-etcd-backup.timer). Three copies per hour is cheap insurance.
resource "aws_s3_bucket" "etcd_backups" {
  bucket = "${var.cluster_name}-etcd-backups-${local.account_id}"
}

resource "aws_s3_bucket_ownership_controls" "etcd_backups" {
  bucket = aws_s3_bucket.etcd_backups.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "etcd_backups" {
  bucket                  = aws_s3_bucket.etcd_backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "etcd_backups" {
  bucket = aws_s3_bucket.etcd_backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "etcd_backups" {
  bucket = aws_s3_bucket.etcd_backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.cluster_secrets_kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "etcd_backups" {
  bucket = aws_s3_bucket.etcd_backups.id

  rule {
    id     = "expire-snapshots"
    status = "Enabled"
    filter {}

    expiration {
      days = var.etcd_backup_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.etcd_backups]
}

data "aws_iam_policy_document" "etcd_backups" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.etcd_backups.arn, "${aws_s3_bucket.etcd_backups.arn}/*"]
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

resource "aws_s3_bucket_policy" "etcd_backups" {
  bucket     = aws_s3_bucket.etcd_backups.id
  policy     = data.aws_iam_policy_document.etcd_backups.json
  depends_on = [aws_s3_bucket_public_access_block.etcd_backups]
}
