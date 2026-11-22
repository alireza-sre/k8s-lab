# Network Load Balancer whose targets are registered from inside the cluster.
#
# Terraform owns the NLB, listeners and (empty) IP target groups, so the DNS
# name and lifecycle never depend on Kubernetes objects. In the cluster,
# aws-load-balancer-controller's TargetGroupBinding registers the gateway
# (Envoy) pod IPs into these target groups, updating them on every rollout.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

resource "aws_security_group" "nlb" {
  name        = "${var.name}-nlb"
  description = "NLB ${var.name}"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-nlb" }
}

resource "aws_vpc_security_group_ingress_rule" "listeners" {
  for_each = {
    for pair in setproduct(keys(var.listeners), var.ingress_cidrs) :
    "${pair[0]}|${pair[1]}" => { listener = pair[0], cidr = pair[1] }
  }
  security_group_id = aws_security_group.nlb.id
  description       = "Clients to listener ${each.value.listener}"
  ip_protocol       = "tcp"
  from_port         = var.listeners[each.value.listener].port
  to_port           = var.listeners[each.value.listener].port
  cidr_ipv4         = each.value.cidr
}

resource "aws_vpc_security_group_egress_rule" "targets" {
  for_each                     = var.listeners
  security_group_id            = aws_security_group.nlb.id
  description                  = "To ${each.key} targets"
  ip_protocol                  = "tcp"
  from_port                    = each.value.target_port
  to_port                      = each.value.target_port
  referenced_security_group_id = var.target_security_group_id
}

# The only path into the target nodes from this NLB: the target ports.
resource "aws_vpc_security_group_ingress_rule" "targets_from_nlb" {
  for_each                     = var.listeners
  security_group_id            = var.target_security_group_id
  description                  = "${var.name} NLB to ${each.key} targets"
  ip_protocol                  = "tcp"
  from_port                    = each.value.target_port
  to_port                      = each.value.target_port
  referenced_security_group_id = aws_security_group.nlb.id
}

resource "aws_lb" "this" {
  name                             = var.name
  internal                         = var.internal
  load_balancer_type               = "network"
  subnets                          = var.subnet_ids
  security_groups                  = [aws_security_group.nlb.id]
  enable_cross_zone_load_balancing = var.cross_zone
  enable_deletion_protection       = var.deletion_protection

  dynamic "access_logs" {
    for_each = var.access_logs_bucket == null ? [] : [1]
    content {
      bucket  = var.access_logs_bucket
      prefix  = var.name
      enabled = true
    }
  }
}

resource "aws_lb_target_group" "this" {
  for_each = var.listeners

  name                 = "${var.name}-${each.key}"
  port                 = each.value.target_port
  protocol             = "TCP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  proxy_protocol_v2    = each.value.proxy_protocol
  deregistration_delay = 30

  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Listener = each.key
  }
}

resource "aws_lb_listener" "this" {
  for_each          = var.listeners
  load_balancer_arn = aws_lb.this.arn
  port              = each.value.port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[each.key].arn
  }
}
