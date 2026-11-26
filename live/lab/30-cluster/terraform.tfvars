# Lab sizing. For production use m7i/c7i classes and larger per-AZ counts.
control_plane_instance_type = "t8i.small" #"t3.large"

node_pools = {
  # CoreDNS is on the control plane; Argo CD, controllers, monitoring live here.
  system = {
    instance_type  = "t8i.small" #"t3.large"
    min_per_az     = 1
    max_per_az     = 2
    desired_per_az = 1
    dedicated      = true
  }
  # Envoy Gateway data plane only; the public NLB targets these pods.
  ingress = {
    instance_type  = "t8i.small" # "t3.medium"
    min_per_az     = 1
    max_per_az     = 3
    desired_per_az = 1
    dedicated      = true
  }
  # Ordinary workloads.
  general = {
    instance_type  = "t8i.small" #"t3.large"
    min_per_az     = 0
    max_per_az     = 5
    desired_per_az = 1
    dedicated      = false
  }
}
