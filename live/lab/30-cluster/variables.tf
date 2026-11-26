variable "node_ami_id" {
  description = "Set in ami.auto.tfvars by the node-ami workflow (or by hand after a local Packer build)."
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.node_ami_id))
    error_message = "node_ami_id must be an AMI ID (build one with packer/ first)."
  }
}

variable "node_kubernetes_version" {
  description = "Informational: the Kubernetes version baked into node_ami_id (written by the node-ami workflow)."
  type        = string
  default     = ""
}

variable "control_plane_instance_type" {
  type    = string
  default = "t3.large"
}

variable "api_allowed_cidrs" {
  description = "VPN/peered CIDRs that may reach the private API endpoint."
  type        = list(string)
  default     = []
}

variable "gitops_repo_url" {
  description = "Defaults to this repository."
  type        = string
  default     = ""
}

variable "gitops_repo_ssh_key_param" {
  description = "SSM SecureString with a read-only deploy key if the GitOps repo is private (use an SSH URL then)."
  type        = string
  default     = ""
}

variable "node_pools" {
  description = "Worker pools. dedicated = tainted so only pods that tolerate <domain>/pool=<name> land there."
  type = map(object({
    instance_type  = string
    min_per_az     = number
    max_per_az     = number
    desired_per_az = number
    dedicated      = bool
  }))
}
