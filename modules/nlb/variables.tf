variable "name" {
  description = "NLB name (max 32 chars); target groups are <name>-<listener>."
  type        = string

  validation {
    condition     = length(var.name) <= 24
    error_message = "Keep name <= 24 chars so <name>-<listener> target group names fit in 32."
  }
}

variable "internal" {
  type = bool
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "ingress_cidrs" {
  description = "Client CIDRs allowed to reach the listeners."
  type        = list(string)
}

variable "listeners" {
  description = <<-EOT
    Map of listener name => settings. target_port is the gateway pod port the
    target group sends to (Envoy Gateway maps privileged listener ports 80/443
    to container ports 10080/10443).
  EOT
  type = map(object({
    port           = number
    target_port    = number
    proxy_protocol = bool
  }))
}

variable "target_security_group_id" {
  description = "Security group on the target nodes (their pod ENIs inherit it); gets ingress from this NLB."
  type        = string
}

variable "cross_zone" {
  type    = bool
  default = true
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "access_logs_bucket" {
  description = "Optional S3 bucket for NLB access logs (bucket policy must allow log delivery)."
  type        = string
  default     = null
}
