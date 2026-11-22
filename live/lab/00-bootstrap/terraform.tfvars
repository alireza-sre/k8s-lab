# Who may assume the deployer role from a workstation. Replace with your own
# admin role/user ARN(s). Patterns are allowed.
admin_principal_arns = [
  "arn:aws:iam::000000000000:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_AdministratorAccess_*",
]

# true only in a fresh account that has never used EC2 Auto Scaling.
create_autoscaling_service_linked_role = false

# Public host name
public_hostname = "lab.fieldstonecloud.net"