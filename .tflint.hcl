config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Add the AWS ruleset (pin its current version):
# plugin "aws" {
#   enabled = true
#   version = "<latest from github.com/terraform-linters/tflint-ruleset-aws>"
#   source  = "github.com/terraform-linters/tflint-ruleset-aws"
# }

# Every layer declares the full common variable set (common.tf) even if it
# doesn't use all of it, so ../common.tfvars can be passed to any layer.
rule "terraform_unused_declarations" {
  enabled = false
}
