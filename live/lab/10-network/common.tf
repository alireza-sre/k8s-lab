# Identical in every layer; values come from ../common.tfvars.
variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "region" {
  type = string
}

variable "deployer_role_arn" {
  type = string
}

variable "github_repository" {
  type = string
}

locals {
  name   = "${var.project}-${var.environment}"
  prefix = "/${var.project}/${var.environment}"
  layer  = "10-network"
}
