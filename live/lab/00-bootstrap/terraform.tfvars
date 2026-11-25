# Who may assume the deployer role from a workstation. Replace with your own
# admin role/user ARN(s). Patterns are allowed.
admin_principal_arns = [
  "arn:aws:iam::000000000000:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_AdministratorAccess_*",
]

# true only in a fresh account that has never used EC2 Auto Scaling.
create_autoscaling_service_linked_role = true

# Immutable OIDC subject of github_repository (IDs are public, not secrets):
#   gh api repos/alireza-sre/k8s-lab/actions/oidc/customization/sub --jq .sub_claim_prefix
github_oidc_subject_prefix = "repo:alireza-sre@206866302/k8s-lab@1467057940"

# Public host name
public_hostname = "lab.fieldstonecloud.net"