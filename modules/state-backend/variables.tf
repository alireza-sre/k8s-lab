variable "name" {
  description = "Name prefix, e.g. kube-ec2-lab. The bucket gets the account ID appended for global uniqueness."
  type        = string
}

variable "kms_deletion_window_days" {
  description = "Waiting period before the state KMS key is deleted."
  type        = number
  default     = 30
}

variable "noncurrent_version_retention_days" {
  description = "How long superseded state versions are kept (your rollback window)."
  type        = number
  default     = 90
}
