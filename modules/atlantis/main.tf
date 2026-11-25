terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    http = {
      source  = "hashicorp/http"
      version = ">= 3.4"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# GitHub publishes the source ranges of webhook deliveries. Only these (plus
# your admin CIDRs) may reach port 443.
data "http" "github_meta" {
  url = "https://api.github.com/meta"
  request_headers = {
    Accept = "application/vnd.github+json"
  }
}

locals {
  github_hook_cidrs_v4 = [
    for c in jsondecode(data.http.github_meta.response_body).hooks : c if !strcontains(c, ":")
  ]
  https_ingress_cidrs = distinct(concat(local.github_hook_cidrs_v4, var.admin_cidrs))
  log_group_name      = "/${var.name}/atlantis"
}

# ---------------------------------------------------------------------------
# Small dedicated VPC. Atlantis never needs to reach the cluster: in-cluster
# bootstrap is done by the control plane itself and everything after that by
# Argo CD, so Atlantis holds no kubeconfig.
# ---------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name}-atlantis" }
}

resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  # No rules: the default SG must never be used.
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-atlantis" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 1, 0)
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.name}-atlantis-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.name}-atlantis-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "atlantis" {
  name        = "${var.name}-atlantis"
  description = "Atlantis server"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-atlantis" }
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  for_each          = toset(local.https_ingress_cidrs)
  security_group_id = aws_security_group.atlantis.id
  description       = "HTTPS from GitHub webhooks / admins"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

# Port 80 only serves Let's Encrypt HTTP-01 challenges and redirects to 443.
resource "aws_vpc_security_group_ingress_rule" "http_acme" {
  security_group_id = aws_security_group.atlantis.id
  description       = "ACME HTTP-01 challenge and redirect"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.atlantis.id
  description       = "GitHub, Terraform registry, AWS APIs"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# Instance
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "atlantis" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
}

resource "aws_instance" "atlantis" {
  ami                    = data.aws_ssm_parameter.al2023.insecure_value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.atlantis.id]
  iam_instance_profile   = aws_iam_instance_profile.atlantis.name

  # Unlimited credits: terraform plans are bursty and throttled CPU makes
  # them time out on a t3.micro.
  credit_specification {
    cpu_credits = "unlimited"
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1 # containers use host networking
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
  }

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", {
    region                     = var.region
    domain_name                = var.domain_name
    atlantis_image             = var.atlantis_image
    caddy_image                = var.caddy_image
    terraform_version          = var.terraform_version
    github_repository          = var.github_repository
    github_app_slug            = var.github_app_slug
    github_app_installation_id = var.github_app_installation_id
    github_team_allowlist      = var.github_team_allowlist
    secrets_prefix             = var.secrets_ssm_prefix
    log_group_name             = local.log_group_name
    acme_email                 = var.acme_email
    repos_yaml = templatefile("${path.module}/templates/repos.yaml.tftpl", {
      github_repository  = var.github_repository
      apply_requirements = var.apply_requirements
    })
    authz_check = file("${path.module}/templates/authz-check.sh")
    authz_sync = templatefile("${path.module}/templates/authz-sync.sh.tftpl", {
      region = var.region
      prefix = var.secrets_ssm_prefix
    })
  })

  tags = { Name = "${var.name}-atlantis" }

  lifecycle {
    # A new AL2023 release should not silently replace the server on every
    # plan. Bump deliberately: terraform apply -replace=module.atlantis.aws_instance.atlantis
    ignore_changes = [ami]
  }

  depends_on = [aws_cloudwatch_log_group.atlantis]
}

# ---------------------------------------------------------------------------
# Authorized GitHub users. Deliberately NOT part of user data: changing the
# lists updates only these parameters, and the instance picks them up within
# a minute (atlantis-authz-sync.timer) without being replaced.
# ---------------------------------------------------------------------------
resource "aws_ssm_parameter" "authorized_users" {
  name        = "${var.secrets_ssm_prefix}/authorized-users"
  description = "GitHub logins allowed to apply and to plan with extra args. Managed by Terraform."
  type        = "String"
  value       = join(" ", sort(distinct([for u in var.authorized_users : lower(u)])))
}

resource "aws_ssm_parameter" "authorized_pr_authors" {
  name        = "${var.secrets_ssm_prefix}/authorized-pr-authors"
  description = "GitHub logins whose PRs Atlantis will plan. Managed by Terraform."
  type        = "String"
  value       = join(" ", sort(distinct([for u in concat(var.authorized_users, var.authorized_pr_bots) : lower(u)])))
}

resource "aws_eip" "atlantis" {
  domain   = "vpc"
  instance = aws_instance.atlantis.id
  tags     = { Name = "${var.name}-atlantis" }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route53_record" "atlantis" {
  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = "A"
  ttl     = 300
  records = [aws_eip.atlantis.public_ip]
}
