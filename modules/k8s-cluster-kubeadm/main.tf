terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_subnet" "selected" {
  for_each = toset(var.subnet_ids)
  id       = each.value
}

# A cluster "generation" scopes all runtime material in SSM (init lock, join
# tokens, encryption key). Destroying and re-creating the cluster yields a
# fresh generation, so a new cluster never trips over a dead one's lock.
resource "random_id" "generation" {
  byte_length = 4
  keepers = {
    cluster_name = var.cluster_name
  }
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  generation = random_id.generation.hex
  ssm_prefix = "${var.ssm_prefix_root}/${local.generation}"
  ssm_arn    = "arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter${local.ssm_prefix}"

  api_fqdn = "api.${var.cluster_name}.${trimsuffix(var.private_zone_name, ".")}"

  cluster_tag = { "kubernetes.io/cluster/${var.cluster_name}" = "owned" }

  # Shared by every node; pools add ROLE/NODE_POOL/labels/taints.
  base_env = {
    CLUSTER_NAME       = var.cluster_name
    CLUSTER_GENERATION = local.generation
    AWS_REGION         = var.region
    SSM_PREFIX         = local.ssm_prefix
    API_ENDPOINT       = local.api_fqdn
    NODE_LABEL_DOMAIN  = var.node_label_domain
  }

  control_plane_env = merge(local.base_env, {
    ROLE                      = "control-plane"
    NODE_POOL                 = "control-plane"
    KMS_KEY_ID                = var.cluster_secrets_kms_key_arn
    API_NLB_DNS               = aws_lb.api.dns_name
    SERVICE_CIDR              = var.service_cidr
    VPC_CIDR                  = var.vpc_cidr
    IRSA_ISSUER_URL           = var.irsa_issuer_url
    IRSA_BUCKET               = var.irsa_bucket_name
    ETCD_BACKUP_BUCKET        = aws_s3_bucket.etcd_backups.bucket
    CILIUM_VERSION            = var.cilium_version
    CCM_CHART_VERSION         = var.ccm_chart_version
    ARGOCD_CHART_VERSION      = var.argocd_chart_version
    GITOPS_REPO_URL           = var.gitops_repo_url
    GITOPS_REVISION           = var.gitops_revision
    GITOPS_PATH               = var.gitops_path
    GITOPS_REPO_SSH_KEY_PARAM = var.gitops_repo_ssh_key_param
  })
}
