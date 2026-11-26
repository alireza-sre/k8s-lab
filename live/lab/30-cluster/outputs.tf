output "api_endpoint" {
  value = module.cluster.api_endpoint
}

output "runtime_ssm_prefix" {
  value = module.cluster.ssm_prefix
}

output "control_plane_asg_names" {
  value = module.cluster.control_plane_asg_names
}

output "pool_asg_names" {
  value = { for k, p in module.pools : k => p.asg_names }
}
