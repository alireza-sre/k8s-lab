variable "name" {
  type = string
}

variable "cluster_name" {
  description = "Used for kubernetes.io/cluster/<name> discovery tags."
  type        = string
}

variable "cidr" {
  type = string
}

variable "azs" {
  type = list(string)

  validation {
    condition     = length(var.azs) >= 3
    error_message = "Use at least 3 AZs so etcd keeps quorum through an AZ failure."
  }
}

variable "public_subnet_cidrs" {
  type = list(string)
}

variable "private_subnet_cidrs" {
  description = "Size generously: in Cilium ENI mode every pod takes a VPC IP from these."
  type        = list(string)
}

variable "single_nat_gateway" {
  description = "Cost saver for throwaway labs. Breaks AZ independence of egress."
  type        = bool
  default     = false
}

variable "interface_endpoints" {
  description = "Interface endpoint service suffixes. Each costs per AZ-hour; trim for cheaper labs. null = default list."
  type        = list(string)
  nullable    = false
  default = [
    "ec2",
    "ecr.api",
    "ecr.dkr",
    "elasticloadbalancing",
    "kms",
    "logs",
    "ssm",
    "ssmmessages",
    "ec2messages",
    "sts",
    "autoscaling",
    "sqs",
  ]
}

variable "flow_log_retention_days" {
  type    = number
  default = 30
}

variable "private_zone_name" {
  description = "Private Route 53 zone, e.g. kube-ec2.internal"
  type        = string
}
