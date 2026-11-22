output "cluster_name" {
  value = var.cluster_name
}

output "generation" {
  value = local.generation
}

output "ssm_prefix" {
  description = "Runtime material: init-lock, initialized, join/*, secrets/*"
  value       = local.ssm_prefix
}

output "api_endpoint" {
  value = local.api_fqdn
}

output "api_nlb_dns_name" {
  value = aws_lb.api.dns_name
}

output "nodes_security_group_id" {
  value = aws_security_group.nodes.id
}

output "control_plane_security_group_id" {
  value = aws_security_group.control_plane.id
}

output "worker_instance_profile_arn" {
  value = aws_iam_instance_profile.worker.arn
}

output "worker_role_arn" {
  value = aws_iam_role.worker.arn
}

output "control_plane_role_arn" {
  value = aws_iam_role.control_plane.arn
}

output "control_plane_asg_names" {
  value = [for a in aws_autoscaling_group.control_plane : a.name]
}

output "node_termination_queue_arn" {
  value = aws_sqs_queue.node_termination.arn
}

output "node_termination_queue_url" {
  value = aws_sqs_queue.node_termination.url
}

output "etcd_backup_bucket" {
  value = aws_s3_bucket.etcd_backups.bucket
}

output "worker_bootstrap_env" {
  description = "Base environment every worker pool merges into its user data."
  value       = local.base_env
}
