output "security_group_id" {
  description = "Pool-specific group, e.g. to admit NLB traffic to ingress nodes."
  value       = aws_security_group.pool.id
}

output "asg_names" {
  value = [for a in aws_autoscaling_group.pool : a.name]
}

output "labels" {
  value = local.labels
}
