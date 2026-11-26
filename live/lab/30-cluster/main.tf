# ---------------------------------------------------------------------------
# Inputs from earlier layers (SSM contract)
# ---------------------------------------------------------------------------
data "aws_ssm_parameter" "network" {
  for_each = toset(["vpc_id", "vpc_cidr", "private_subnet_ids", "private_zone_id", "private_zone_name"])
  name     = "${local.prefix}/10-network/${each.key}"
}

data "aws_ssm_parameter" "identity" {
  for_each = toset([
    "cluster_secrets_kms_key_arn",
    "ebs_kms_key_arn",
    "irsa_issuer_url",
    "irsa_bucket_name",
    "irsa_bucket_arn",
  ])
  name = "${local.prefix}/20-identity/${each.key}"
}

locals {
  net = { for k, p in data.aws_ssm_parameter.network : k => p.insecure_value }
  id  = { for k, p in data.aws_ssm_parameter.identity : k => p.insecure_value }

  private_subnet_ids = jsondecode(local.net.private_subnet_ids)
  label_domain       = "node.${var.project}.io"
  gitops_repo_url    = coalesce(var.gitops_repo_url, "https://github.com/${var.github_repository}.git")
}

# ---------------------------------------------------------------------------
# Control plane + cluster-wide resources
# ---------------------------------------------------------------------------
module "cluster" {
  source = "../../../modules/k8s-cluster-kubeadm"

  cluster_name      = local.name
  region            = var.region
  node_label_domain = local.label_domain

  vpc_id            = local.net.vpc_id
  vpc_cidr          = local.net.vpc_cidr
  subnet_ids        = local.private_subnet_ids
  private_zone_id   = local.net.private_zone_id
  private_zone_name = local.net.private_zone_name
  api_allowed_cidrs = var.api_allowed_cidrs

  cluster_secrets_kms_key_arn = local.id.cluster_secrets_kms_key_arn
  ebs_kms_key_arn             = local.id.ebs_kms_key_arn
  irsa_issuer_url             = local.id.irsa_issuer_url
  irsa_bucket_name            = local.id.irsa_bucket_name
  irsa_bucket_arn             = local.id.irsa_bucket_arn

  ami_id                      = var.node_ami_id
  control_plane_instance_type = var.control_plane_instance_type
  ssm_prefix_root             = "${local.prefix}/cluster"

  gitops_repo_url           = local.gitops_repo_url
  gitops_revision           = "main"
  gitops_path               = "gitops/clusters/${var.environment}"
  gitops_repo_ssh_key_param = var.gitops_repo_ssh_key_param
}

# ---------------------------------------------------------------------------
# Worker pools
# ---------------------------------------------------------------------------
module "pools" {
  source   = "../../../modules/k8s-node-pool"
  for_each = var.node_pools

  name          = each.key
  cluster_name  = local.name
  vpc_id        = local.net.vpc_id
  subnet_ids    = local.private_subnet_ids
  ami_id        = var.node_ami_id
  instance_type = each.value.instance_type

  min_size_per_az     = each.value.min_per_az
  max_size_per_az     = each.value.max_per_az
  desired_size_per_az = each.value.desired_per_az

  label_domain = local.label_domain
  taints = each.value.dedicated ? [{
    key    = "${local.label_domain}/pool"
    value  = each.key
    effect = "NoSchedule"
  }] : []

  bootstrap_env           = module.cluster.worker_bootstrap_env
  nodes_security_group_id = module.cluster.nodes_security_group_id
  instance_profile_arn    = module.cluster.worker_instance_profile_arn
  ebs_kms_key_arn         = local.id.ebs_kms_key_arn
}

# ---------------------------------------------------------------------------
# Contract for 40-edge, 50-platform-iam and the GitOps repo
# ---------------------------------------------------------------------------
module "outputs" {
  source = "../../../modules/ssm-outputs"
  prefix = "${local.prefix}/${local.layer}"
  values = merge(
    {
      cluster_name               = module.cluster.cluster_name
      generation                 = module.cluster.generation
      runtime_ssm_prefix         = module.cluster.ssm_prefix
      api_endpoint               = module.cluster.api_endpoint
      nodes_security_group_id    = module.cluster.nodes_security_group_id
      node_termination_queue_arn = module.cluster.node_termination_queue_arn
      node_termination_queue_url = module.cluster.node_termination_queue_url
      etcd_backup_bucket         = module.cluster.etcd_backup_bucket
      control_plane_asg_names    = jsonencode(module.cluster.control_plane_asg_names)
      node_label_domain          = local.label_domain
      node_ami_id                = var.node_ami_id
    },
    { for k, p in module.pools : "pool_${k}_security_group_id" => p.security_group_id },
    { for k, p in module.pools : "pool_${k}_asg_names" => jsonencode(p.asg_names) },
  )
}
