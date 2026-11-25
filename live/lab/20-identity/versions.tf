terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.71"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.4"
    }
  }

  # bucket/region/kms/lockfile come from ../backend.hcl
  #   terraform init -backend-config=../backend.hcl
  backend "s3" {
    key = "20-identity/terraform.tfstate"
  }
}

provider "aws" {
  region = var.region

  # State: caller's own identity (Atlantis instance role or you).
  # Resources: only through the deployer role.
  assume_role {
    role_arn     = var.deployer_role_arn
    session_name = "terraform-20-identity"
  }

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      Layer       = "20-identity"
      ManagedBy   = "terraform"
      Repository  = var.github_repository
    }
  }
}
