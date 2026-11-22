terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.71"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.6"
    }
  }

  # bucket/region/kms/lockfile come from ../backend.hcl (terraform init -backend-config=../backend.hcl)
  backend "s3" {
    key = "05-atlantis/terraform.tfstate"
  }
}

provider "aws" {
  region = var.region

  # State is read/written with the caller's own identity (backend above);
  # resources are changed only through the deployer role.
  assume_role {
    role_arn     = var.deployer_role_arn
    session_name = "terraform-05-atlantis"
  }

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      Layer       = "05-atlantis"
      ManagedBy   = "terraform"
      Repository  = var.github_repository
    }
  }
}
