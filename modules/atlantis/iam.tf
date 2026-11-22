data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "atlantis" {
  # Must match the name 00-bootstrap trusts in the deployer role.
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.atlantis.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "atlantis" {
  # Infrastructure changes happen only through the deployer role.
  statement {
    sid       = "AssumeDeployer"
    actions   = ["sts:AssumeRole", "sts:TagSession"]
    resources = [var.deployer_role_arn]
  }

  # Read/write Terraform state with the instance's own identity.
  statement {
    sid       = "StateList"
    actions   = ["s3:ListBucket"]
    resources = [var.state_bucket_arn]
  }

  statement {
    sid       = "StateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${var.state_bucket_arn}/*"]
  }

  statement {
    sid       = "StateKms"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [var.state_kms_key_arn]
  }

  statement {
    sid     = "ReadOwnSecrets"
    actions = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = [
      "arn:${data.aws_partition.current.partition}:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.secrets_ssm_prefix}/*",
    ]
  }

  statement {
    sid       = "ShipLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["${aws_cloudwatch_log_group.atlantis.arn}:*"]
  }
}

resource "aws_iam_role_policy" "atlantis" {
  name   = "atlantis"
  role   = aws_iam_role.atlantis.id
  policy = data.aws_iam_policy_document.atlantis.json
}

resource "aws_iam_instance_profile" "atlantis" {
  name = var.role_name
  role = aws_iam_role.atlantis.name
}
