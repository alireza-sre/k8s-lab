variable "cluster_name" {
  type = string

  validation {
    condition     = can(regex("^[a-z0-9-]{3,20}$", var.cluster_name))
    error_message = "3-20 chars of [a-z0-9-] (load balancer names are limited to 32 chars)."
  }
}

variable "region" {
  type = string
}

variable "node_label_domain" {
  description = "Domain for node pool labels/taints, e.g. node.kube-ec2.io"
  type        = string
}

# --- network (from 10-network) ---
variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "subnet_ids" {
  description = "Private subnets, one per AZ. One control-plane node is placed in each."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) == 3
    error_message = "Exactly 3 subnets (one per AZ) for a 3-member etcd."
  }
}

variable "private_zone_id" {
  type = string
}

variable "private_zone_name" {
  type = string
}

variable "api_allowed_cidrs" {
  description = "Extra CIDRs (e.g. VPN) that may reach the API NLB. The VPC CIDR is always allowed."
  type        = list(string)
  default     = []
}

# --- identity (from 20-identity) ---
variable "cluster_secrets_kms_key_arn" {
  type = string
}

variable "ebs_kms_key_arn" {
  type = string
}

variable "irsa_issuer_url" {
  type = string
}

variable "irsa_bucket_name" {
  type = string
}

variable "irsa_bucket_arn" {
  type = string
}

# --- control plane ---
variable "ami_id" {
  description = "Node AMI built by packer/ (contains kubeadm and the bootstrap scripts; defines the Kubernetes version)."
  type        = string
}

variable "control_plane_instance_type" {
  type    = string
  default = "m7i.large"
}

variable "control_plane_root_volume_gb" {
  type    = number
  default = 50
}

variable "etcd_volume_gb" {
  type    = number
  default = 20
}

variable "etcd_volume_iops" {
  type    = number
  default = 3000
}

variable "etcd_volume_throughput" {
  type    = number
  default = 125
}

variable "service_cidr" {
  description = "Kubernetes Service CIDR; must not overlap the VPC."
  type        = string
  default     = "172.20.0.0/16"
}

variable "ssm_prefix_root" {
  description = "Root SSM path for runtime cluster material, e.g. /kube-ec2/lab/cluster. A generation suffix is appended."
  type        = string
}

variable "etcd_backup_retention_days" {
  type    = number
  default = 14
}

# --- in-cluster bootstrap (installed once by the first control-plane node,
#     then adopted by Argo CD) ---
variable "cilium_version" {
  type    = string
  default = "1.20.4"
}

variable "ccm_chart_version" {
  description = "aws-cloud-controller-manager Helm chart version."
  type        = string
  default     = "0.0.12"
}

variable "argocd_chart_version" {
  type    = string
  default = "10.11.6"
}

variable "gitops_repo_url" {
  description = "Repository Argo CD's root Application points at. Empty = skip root app."
  type        = string
  default     = ""
}

variable "gitops_revision" {
  type    = string
  default = "main"
}

variable "gitops_path" {
  type    = string
  default = "gitops/clusters/lab"
}

variable "gitops_repo_ssh_key_param" {
  description = "Optional SSM SecureString holding an SSH deploy key for a private GitOps repo."
  type        = string
  default     = ""
}
