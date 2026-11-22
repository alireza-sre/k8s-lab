output "url" {
  value = "https://${var.domain_name}"
}

output "webhook_url" {
  description = "Set this as the GitHub App webhook URL."
  value       = "https://${var.domain_name}/events"
}

output "public_ip" {
  value = aws_eip.atlantis.public_ip
}

output "instance_id" {
  value = aws_instance.atlantis.id
}

output "role_arn" {
  value = aws_iam_role.atlantis.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.atlantis.name
}
