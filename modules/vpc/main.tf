terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

data "aws_region" "current" {}

locals {
  az_count  = length(var.azs)
  nat_count = var.single_nat_gateway ? 1 : local.az_count

  cluster_tag = { "kubernetes.io/cluster/${var.cluster_name}" = "shared" }
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # required: node names are EC2 private DNS names
  tags                 = merge({ Name = var.name }, local.cluster_tag)
}

# CIS: the default security group must allow nothing.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-default-do-not-use" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.name }
}

# ---------------------------------------------------------------------------
# Subnets
#   public:  only load balancers and NAT gateways live here
#   private: control plane, nodes and (Cilium ENI mode) pod IPs
# ---------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count                   = local.az_count
  vpc_id                  = aws_vpc.this.id
  availability_zone       = var.azs[count.index]
  cidr_block              = var.public_subnet_cidrs[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.cluster_tag, {
    Name                     = "${var.name}-public-${var.azs[count.index]}"
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_subnet" "private" {
  count             = local.az_count
  vpc_id            = aws_vpc.this.id
  availability_zone = var.azs[count.index]
  cidr_block        = var.private_subnet_cidrs[count.index]

  tags = merge(local.cluster_tag, {
    Name                              = "${var.name}-private-${var.azs[count.index]}"
    Tier                              = "private"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = local.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# NAT: one per AZ by default so an AZ outage never breaks egress elsewhere.
# ---------------------------------------------------------------------------
resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"
  tags   = { Name = "${var.name}-nat-${var.azs[count.index]}" }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count         = local.nat_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = { Name = "${var.name}-${var.azs[count.index]}" }
}

resource "aws_route_table" "private" {
  count  = local.az_count
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-private-${var.azs[count.index]}" }
}

resource "aws_route" "private_nat" {
  count                  = local.az_count
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
}

resource "aws_route_table_association" "private" {
  count          = local.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ---------------------------------------------------------------------------
# VPC endpoints: keep AWS API and image traffic off the NAT gateways and make
# node bootstrap independent of internet egress.
# ---------------------------------------------------------------------------
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id
  tags              = { Name = "${var.name}-s3" }
}

resource "aws_security_group" "endpoints" {
  name        = "${var.name}-vpc-endpoints"
  description = "HTTPS from inside the VPC to interface endpoints"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-vpc-endpoints" }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  security_group_id = aws_security_group.endpoints.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = aws_vpc.this.cidr_block
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(var.interface_endpoints)

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  tags                = { Name = "${var.name}-${each.value}" }
}

# ---------------------------------------------------------------------------
# Flow logs
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/${var.name}/vpc-flow-logs"
  retention_in_days = var.flow_log_retention_days
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${var.name}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
}

data "aws_iam_policy_document" "flow_logs" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs.json
}

resource "aws_flow_log" "this" {
  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 60
}

# ---------------------------------------------------------------------------
# Private DNS for the API endpoint and other internal names.
# ---------------------------------------------------------------------------
resource "aws_route53_zone" "private" {
  name    = var.private_zone_name
  comment = "Private zone for ${var.name}"

  vpc {
    vpc_id = aws_vpc.this.id
  }
}
