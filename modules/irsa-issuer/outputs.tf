output "issuer_url" {
  description = "Value for --service-account-issuer."
  value       = local.issuer_url
}

output "issuer_host" {
  description = "Issuer without scheme; the prefix of IAM trust-policy condition keys."
  value       = local.issuer_host
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.this.arn
}

output "bucket_name" {
  value = aws_s3_bucket.oidc.bucket
}

output "bucket_arn" {
  value = aws_s3_bucket.oidc.arn
}
