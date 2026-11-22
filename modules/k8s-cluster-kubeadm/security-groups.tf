# Security group model
#
#   nodes          on EVERY node (control plane and workers). In Cilium ENI mode
#                  pod ENIs inherit the node's groups, so this group also
#                  carries pod-to-pod traffic: all protocols from itself.
#   control-plane  extra group on control-plane nodes: API from the NLB.
#   api-nlb        on the internal API NLB: 6443 from the VPC (+ VPN CIDRs).
#
# Finer east-west control (e.g. etcd ports only between control-plane nodes,
# kubelet only from the API server) belongs in Cilium host-firewall policies,
# because pod traffic shares these groups.

resource "aws_security_group" "nodes" {
  name        = "${var.cluster_name}-nodes"
  description = "All Kubernetes nodes and (ENI mode) their pods"
  vpc_id      = var.vpc_id
  tags        = merge(local.cluster_tag, { Name = "${var.cluster_name}-nodes" })
}

resource "aws_vpc_security_group_ingress_rule" "nodes_self" {
  security_group_id            = aws_security_group.nodes.id
  description                  = "Node-to-node and pod-to-pod"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.nodes.id
}

resource "aws_vpc_security_group_egress_rule" "nodes_all" {
  security_group_id = aws_security_group.nodes.id
  description       = "Image pulls via NAT, AWS APIs via endpoints"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "control_plane" {
  name        = "${var.cluster_name}-control-plane"
  description = "Kubernetes control-plane nodes"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.cluster_name}-control-plane" }
}

resource "aws_vpc_security_group_ingress_rule" "cp_api_from_nlb" {
  security_group_id            = aws_security_group.control_plane.id
  description                  = "kube-apiserver via the internal NLB"
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  referenced_security_group_id = aws_security_group.api_nlb.id
}

resource "aws_security_group" "api_nlb" {
  name        = "${var.cluster_name}-api-nlb"
  description = "Internal NLB in front of kube-apiserver"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.cluster_name}-api-nlb" }
}

resource "aws_vpc_security_group_ingress_rule" "api_nlb_in" {
  for_each          = toset(concat([var.vpc_cidr], var.api_allowed_cidrs))
  security_group_id = aws_security_group.api_nlb.id
  description       = "Kubernetes API clients"
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "api_nlb_out" {
  security_group_id            = aws_security_group.api_nlb.id
  description                  = "Forward to kube-apiserver"
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  referenced_security_group_id = aws_security_group.control_plane.id
}
