output "url" {
  value = module.atlantis.url
}

output "webhook_url" {
  value = module.atlantis.webhook_url
}

output "instance_id" {
  description = "Shell access: aws ssm start-session --target <id>"
  value       = module.atlantis.instance_id
}
