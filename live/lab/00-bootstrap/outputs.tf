# scripts/bootstrap-backend.sh reads these to write ../backend.hcl.
output "state_bucket_name" {
  value = module.state_backend.bucket_name
}

output "state_kms_key_arn" {
  value = module.state_backend.kms_key_arn
}

output "deployer_role_arn" {
  value = aws_iam_role.deployer.arn
}

output "github_packer_role_arn" {
  description = "Set as the PACKER_ROLE_ARN variable of the ami-build environment in GitHub."
  value       = module.github_packer_role.role_arn
}

output "public_zone_id" {
  value = aws_route53_zone.public.zone_id
}

output "public_zone_name_servers" {
  value = aws_route53_zone.public.name_servers
}