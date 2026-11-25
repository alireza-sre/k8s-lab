data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  autoscaling_slr_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"
}

# Encrypts cluster secrets that live outside the cluster: join material and
# the secretbox key in SSM, etcd snapshots in S3.
module "cluster_secrets_key" {
  source      = "../../../modules/kms-key"
  alias       = "${local.name}-cluster-secrets"
  description = "Cluster bootstrap secrets and etcd backups for ${local.name}"
}

# Encrypts node root/etcd volumes and EBS CSI volumes. Auto Scaling must be
# able to use it, or instances fail to launch with Client.InternalError.
module "ebs_key" {
  source                   = "../../../modules/kms-key"
  alias                    = "${local.name}-ebs"
  description              = "EBS volumes for ${local.name}"
  service_linked_role_arns = [local.autoscaling_slr_arn]
}

module "irsa_issuer" {
  source = "../../../modules/irsa-issuer"
  name   = local.name
}

module "outputs" {
  source = "../../../modules/ssm-outputs"
  prefix = "${local.prefix}/${local.layer}"
  values = {
    cluster_secrets_kms_key_arn = module.cluster_secrets_key.key_arn
    ebs_kms_key_arn             = module.ebs_key.key_arn
    irsa_issuer_url             = module.irsa_issuer.issuer_url
    irsa_issuer_host            = module.irsa_issuer.issuer_host
    irsa_oidc_provider_arn      = module.irsa_issuer.oidc_provider_arn
    irsa_bucket_name            = module.irsa_issuer.bucket_name
    irsa_bucket_arn             = module.irsa_issuer.bucket_arn
  }
}

output "irsa_issuer_url" {
  value = module.irsa_issuer.issuer_url
}
