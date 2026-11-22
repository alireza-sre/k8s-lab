data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

locals {
  node_managed_policies = [
    "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ]
}

# ===========================================================================
# Control plane
# The instance profile is shared by host-network components that run only on
# control-plane nodes: kubeadm bootstrap scripts, aws-cloud-controller-manager
# and cilium-operator (ENI IPAM). Everything else uses IRSA (50-platform-iam).
# ===========================================================================
resource "aws_iam_role" "control_plane" {
  name               = "${var.cluster_name}-control-plane"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "control_plane_managed" {
  for_each   = toset(local.node_managed_policies)
  role       = aws_iam_role.control_plane.name
  policy_arn = each.value
}

data "aws_iam_policy_document" "control_plane" {
  statement {
    sid = "BootstrapMaterial"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:PutParameter",
    ]
    resources = ["${local.ssm_arn}/*"]
  }

  statement {
    sid     = "GitOpsDeployKey"
    actions = ["ssm:GetParameter"]
    resources = [
      var.gitops_repo_ssh_key_param == "" ? "${local.ssm_arn}/none" :
      "arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter${var.gitops_repo_ssh_key_param}",
    ]
  }

  statement {
    sid       = "ClusterSecretsKey"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = [var.cluster_secrets_kms_key_arn]
  }

  statement {
    sid       = "PublishOidcDiscovery"
    actions   = ["s3:PutObject"]
    resources = ["${var.irsa_bucket_arn}/.well-known/openid-configuration", "${var.irsa_bucket_arn}/openid/v1/jwks"]
  }

  statement {
    sid       = "EtcdBackups"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.etcd_backups.arn}/${var.cluster_name}/*"]
  }

  # aws-cloud-controller-manager (node + node-lifecycle controllers only;
  # the service and route controllers are disabled).
  statement {
    sid = "CloudControllerManager"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTopology",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeRegions",
      "ec2:DescribeSubnets",
      "ec2:DescribeVpcs",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeRouteTables",
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeTags",
      "kms:DescribeKey",
    ]
    resources = ["*"]
  }

  # cilium-operator in ENI IPAM mode: allocates ENIs and IPs/prefixes for pods.
  statement {
    sid = "CiliumEniIpam"
    actions = [
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeSubnets",
      "ec2:DescribeVpcs",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeInstances",
      "ec2:CreateNetworkInterface",
      "ec2:AttachNetworkInterface",
      "ec2:DetachNetworkInterface",
      "ec2:DeleteNetworkInterface",
      "ec2:ModifyNetworkInterfaceAttribute",
      "ec2:AssignPrivateIpAddresses",
      "ec2:UnassignPrivateIpAddresses",
      "ec2:CreateTags",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "control_plane" {
  name   = "control-plane"
  role   = aws_iam_role.control_plane.id
  policy = data.aws_iam_policy_document.control_plane.json
}

resource "aws_iam_instance_profile" "control_plane" {
  name = "${var.cluster_name}-control-plane"
  role = aws_iam_role.control_plane.name
}

# ===========================================================================
# Workers: only enough to join. Pods cannot reach IMDS (hop limit 1), so they
# never inherit these permissions; workloads use IRSA.
# ===========================================================================
resource "aws_iam_role" "worker" {
  name               = "${var.cluster_name}-worker"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "worker_managed" {
  for_each   = toset(local.node_managed_policies)
  role       = aws_iam_role.worker.name
  policy_arn = each.value
}

data "aws_iam_policy_document" "worker" {
  statement {
    sid     = "JoinMaterial"
    actions = ["ssm:GetParameter"]
    resources = [
      "${local.ssm_arn}/initialized",
      "${local.ssm_arn}/join/token",
      "${local.ssm_arn}/join/ca-cert-hash",
    ]
  }

  statement {
    sid       = "DecryptJoinToken"
    actions   = ["kms:Decrypt"]
    resources = [var.cluster_secrets_kms_key_arn]
  }
}

resource "aws_iam_role_policy" "worker" {
  name   = "worker"
  role   = aws_iam_role.worker.id
  policy = data.aws_iam_policy_document.worker.json
}

resource "aws_iam_instance_profile" "worker" {
  name = "${var.cluster_name}-worker"
  role = aws_iam_role.worker.name
}
