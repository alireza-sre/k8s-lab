terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.71"
    }
  }

  # On the very first run this file is moved aside by
  # scripts/bootstrap-backend.sh so the layer applies with local state, then
  # restored and the state is migrated into the bucket it just created.
  backend "s3" {
    key = "00-bootstrap/terraform.tfstate"
  }
}

provider "aws" {
  region = var.region

  # Applied with your own admin credentials, NOT the deployer role:
  # this layer creates the deployer role.
  default_tags {
    tags = local.tags
  }
}
