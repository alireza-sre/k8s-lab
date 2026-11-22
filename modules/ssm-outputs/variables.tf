variable "prefix" {
  description = "Parameter path prefix, e.g. /kube-ec2/lab/10-network. No trailing slash."
  type        = string

  validation {
    condition     = can(regex("^/[A-Za-z0-9_./-]+[^/]$", var.prefix))
    error_message = "prefix must start with '/' and must not end with '/'."
  }
}

variable "values" {
  description = "Map of key => string value. Encode lists/maps with jsonencode(). Never pass secrets here."
  type        = map(string)
}
