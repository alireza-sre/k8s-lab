# Three single-instance ASGs, one per AZ. Each self-heals its own node; the
# replacement joins as a new etcd member after the survivors' reconciler
# (k8s-etcd-reconcile.timer) removes the dead member.
#
# There is deliberately NO instance_refresh: a launch template change must
# never replace all three members at once. Roll them one by one with
# scripts/roll-control-plane.sh, which waits for etcd health between nodes.

resource "aws_launch_template" "control_plane" {
  name_prefix            = "${var.cluster_name}-control-plane-"
  image_id               = var.ami_id
  instance_type          = var.control_plane_instance_type
  update_default_version = true
  vpc_security_group_ids = [aws_security_group.nodes.id, aws_security_group.control_plane.id]

  iam_instance_profile {
    arn = aws_iam_instance_profile.control_plane.arn
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1 # pods (not hostNetwork) can't reach IMDS
    instance_metadata_tags      = "disabled"
  }

  block_device_mappings {
    device_name = "/dev/sda1" # Ubuntu root device
    ebs {
      volume_type           = "gp3"
      volume_size           = var.control_plane_root_volume_gb
      encrypted             = true
      kms_key_id            = var.ebs_kms_key_arn
      delete_on_termination = true
    }
  }

  # Dedicated etcd volume: isolates etcd fsync latency from logs and images.
  block_device_mappings {
    device_name = "/dev/sdf"
    ebs {
      volume_type           = "gp3"
      volume_size           = var.etcd_volume_gb
      iops                  = var.etcd_volume_iops
      throughput            = var.etcd_volume_throughput
      encrypted             = true
      kms_key_id            = var.ebs_kms_key_arn
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = true
  }

  user_data = base64encode(templatefile("${path.module}/templates/user-data.yaml.tftpl", {
    env = local.control_plane_env
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.cluster_tag, {
      Name                        = "${var.cluster_name}-control-plane"
      "k8s.io/node-pool"          = "control-plane"
      "k8s.io/role/control-plane" = "1"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.cluster_tag, { Name = "${var.cluster_name}-control-plane" })
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "control_plane" {
  for_each = { for s in var.subnet_ids : data.aws_subnet.selected[s].availability_zone => s }

  name                      = "${var.cluster_name}-cp-${each.key}"
  min_size                  = 1
  max_size                  = 1
  desired_capacity          = 1
  vpc_zone_identifier       = [each.value]
  target_group_arns         = [aws_lb_target_group.api.arn]
  health_check_type         = "EC2" # an unready apiserver must not get its etcd member killed
  health_check_grace_period = 600
  default_instance_warmup   = 300
  capacity_rebalance        = false
  protect_from_scale_in     = false

  launch_template {
    id      = aws_launch_template.control_plane.id
    version = aws_launch_template.control_plane.latest_version
  }

  initial_lifecycle_hook {
    name                 = "node-termination-handler"
    lifecycle_transition = "autoscaling:EC2_INSTANCE_TERMINATING"
    heartbeat_timeout    = 300
    default_result       = "CONTINUE"
  }

  enabled_metrics = ["GroupInServiceInstances", "GroupDesiredCapacity", "GroupTerminatingInstances"]

  tag {
    key                 = "kubernetes.io/cluster/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = true
  }

  tag {
    key                 = "aws-node-termination-handler/managed"
    value               = ""
    propagate_at_launch = true
  }

  lifecycle {
    # A new launch template version is picked up by the next replacement only.
    ignore_changes = [desired_capacity]
  }
}
