variable "name" {
  description = "Pool name, e.g. system, ingress, general."
  type        = string
}

variable "cluster_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "One ASG is created per subnet (AZ)."
  type        = list(string)
}

variable "ami_id" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "root_volume_gb" {
  type    = number
  default = 50
}

variable "min_size_per_az" {
  type    = number
  default = 1
}

variable "max_size_per_az" {
  type    = number
  default = 3
}

variable "desired_size_per_az" {
  type    = number
  default = 1
}

variable "refresh_min_healthy_percentage" {
  type    = number
  default = 66
}

variable "label_domain" {
  description = "Domain for the pool label, e.g. node.kube-ec2.io => node.kube-ec2.io/pool=<name>."
  type        = string
}

variable "labels" {
  description = "Extra node labels. node-role.kubernetes.io/* is not allowed (NodeRestriction)."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.labels) : !startswith(k, "node-role.kubernetes.io/")])
    error_message = "The kubelet cannot self-assign node-role.kubernetes.io/* labels."
  }
}

variable "taints" {
  type = list(object({
    key    = string
    value  = string
    effect = string
  }))
  default = []
}

variable "enable_cluster_autoscaler" {
  type    = bool
  default = true
}

# --- from the cluster module ---
variable "bootstrap_env" {
  type = map(string)
}

variable "nodes_security_group_id" {
  type = string
}

variable "extra_security_group_ids" {
  type    = list(string)
  default = []
}

variable "instance_profile_arn" {
  type = string
}

variable "ebs_kms_key_arn" {
  type = string
}
