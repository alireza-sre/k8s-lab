# A worker pool = one ASG per AZ (so cluster-autoscaler can scale AZ-aware
# with --balance-similar-node-groups) sharing one launch template.
#
# Labels/taints are applied by the kubelet at registration. The kubelet may
# not set node-role.kubernetes.io/* itself (NodeRestriction), hence the
# custom node.<domain>/pool label.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

data "aws_subnet" "selected" {
  for_each = toset(var.subnet_ids)
  id       = each.value
}

locals {
  full_name = "${var.cluster_name}-${var.name}"

  labels = merge({ "${var.label_domain}/pool" = var.name }, var.labels)
  taints = [for t in var.taints : "${t.key}=${t.value}:${t.effect}"]

  env = merge(var.bootstrap_env, {
    ROLE        = "worker"
    NODE_POOL   = var.name
    NODE_LABELS = join(",", [for k, v in local.labels : "${k}=${v}"])
    NODE_TAINTS = join(",", local.taints)
  })

  # Tags cluster-autoscaler reads to scale a pool up from zero.
  ca_template_tags = merge(
    { for k, v in local.labels : "k8s.io/cluster-autoscaler/node-template/label/${k}" => v },
    { for t in var.taints : "k8s.io/cluster-autoscaler/node-template/taint/${t.key}" => "${t.value}:${t.effect}" },
  )

  asg_tags = merge(
    {
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
      "aws-node-termination-handler/managed"      = ""
      "k8s.io/node-pool"                          = var.name
    },
    var.enable_cluster_autoscaler ? merge({
      "k8s.io/cluster-autoscaler/enabled"             = "true"
      "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
    }, local.ca_template_tags) : {},
  )
}

resource "aws_security_group" "pool" {
  name        = local.full_name
  description = "Pool-specific rules for ${local.full_name} (e.g. NLB targets)"
  vpc_id      = var.vpc_id
  tags        = { Name = local.full_name }
}

resource "aws_launch_template" "pool" {
  name_prefix            = "${local.full_name}-"
  image_id               = var.ami_id
  instance_type          = var.instance_type
  update_default_version = true
  vpc_security_group_ids = concat([var.nodes_security_group_id, aws_security_group.pool.id], var.extra_security_group_ids)

  iam_instance_profile {
    arn = var.instance_profile_arn
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_gb
      encrypted             = true
      kms_key_id            = var.ebs_kms_key_arn
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = true
  }

  user_data = base64encode(templatefile("${path.module}/templates/user-data.yaml.tftpl", {
    env = local.env
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name                                        = local.full_name
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
      "k8s.io/node-pool"                          = var.name
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = local.full_name }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "pool" {
  for_each = { for s in var.subnet_ids : data.aws_subnet.selected[s].availability_zone => s }

  name                      = "${local.full_name}-${each.key}"
  min_size                  = var.min_size_per_az
  max_size                  = var.max_size_per_az
  desired_capacity          = var.desired_size_per_az
  vpc_zone_identifier       = [each.value]
  health_check_type         = "EC2"
  health_check_grace_period = 300
  default_instance_warmup   = 180
  capacity_rebalance        = true

  launch_template {
    id      = aws_launch_template.pool.id
    version = aws_launch_template.pool.latest_version
  }

  # A new AMI or user data rolls the pool, draining nodes through the
  # termination lifecycle hook (node-termination-handler).
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = var.refresh_min_healthy_percentage
      instance_warmup        = 180
      skip_matching          = true
    }
  }

  initial_lifecycle_hook {
    name                 = "node-termination-handler"
    lifecycle_transition = "autoscaling:EC2_INSTANCE_TERMINATING"
    heartbeat_timeout    = 300
    default_result       = "CONTINUE"
  }

  enabled_metrics = ["GroupInServiceInstances", "GroupDesiredCapacity", "GroupTerminatingInstances"]

  dynamic "tag" {
    for_each = local.asg_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    # cluster-autoscaler owns desired capacity once the cluster runs.
    ignore_changes = [desired_capacity]
  }
}
