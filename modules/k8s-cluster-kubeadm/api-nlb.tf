# Internal NLB that is the cluster's controlPlaneEndpoint.
#
# preserve_client_ip = false avoids the NLB "hairpin" problem: with client IP
# preservation, a control-plane node calling the NLB and being routed to
# itself sees its own IP as both source and destination and the connection
# hangs. Kubernetes doesn't need client IPs here (authn is mTLS/tokens).
resource "aws_lb" "api" {
  name                             = "${var.cluster_name}-api"
  internal                         = true
  load_balancer_type               = "network"
  subnets                          = var.subnet_ids
  security_groups                  = [aws_security_group.api_nlb.id]
  enable_cross_zone_load_balancing = true
  enable_deletion_protection       = false
  tags                             = local.cluster_tag
}

resource "aws_lb_target_group" "api" {
  name                   = "${var.cluster_name}-api"
  port                   = 6443
  protocol               = "TCP"
  target_type            = "instance"
  vpc_id                 = var.vpc_id
  preserve_client_ip     = false
  deregistration_delay   = 30
  connection_termination = true

  # /readyz is readable anonymously (system:public-info-viewer) and turns
  # unready while the apiserver can't reach etcd.
  health_check {
    protocol            = "HTTPS"
    port                = "traffic-port"
    path                = "/readyz"
    matcher             = "200"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.api.arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

resource "aws_route53_record" "api" {
  zone_id = var.private_zone_id
  name    = local.api_fqdn
  type    = "A"

  alias {
    name                   = aws_lb.api.dns_name
    zone_id                = aws_lb.api.zone_id
    evaluate_target_health = false
  }
}
