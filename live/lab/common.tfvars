# Shared by every layer in this environment.
# Locally:  terraform plan -var-file=../common.tfvars
# Atlantis: passed automatically by the server-side "layered" workflow.

project     = "k8s-lab"
environment = "lab"
region      = "eu-central-1"

# Written by scripts/bootstrap-backend.sh once 00-bootstrap exists.
# Every layer from 05 onwards assumes this role for AWS changes.
deployer_role_arn = "arn:aws:iam::002651652420:role/k8s-lab-lab-terraform-deployer"

# GitHub repository that holds this code (owner/name).
github_repository = "alireza-sre/k8s-lab"
