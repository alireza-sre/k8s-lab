# Publishes a layer's outputs to SSM Parameter Store as the cross-layer contract:
#
#   /<project>/<environment>/<layer>/<key>
#
# Consumers read single values with `data "aws_ssm_parameter"`. This avoids
# terraform_remote_state, which needs read access to the producer's whole
# state file (including any secrets in it) and couples consumers to the
# producer's backend layout. Lists and maps are stored JSON-encoded.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

resource "aws_ssm_parameter" "this" {
  for_each = var.values

  name        = "${var.prefix}/${each.key}"
  description = "Output of layer ${var.prefix}. Managed by Terraform; do not edit."
  type        = "String"
  value       = each.value
  tier        = length(each.value) > 4096 ? "Advanced" : "Standard"
}
