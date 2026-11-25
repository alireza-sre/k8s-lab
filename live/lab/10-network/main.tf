variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "single_nat_gateway" {
  type    = bool
  default = false
}

variable "interface_endpoints" {
  type    = list(string)
  default = null
}

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(sort(data.aws_availability_zones.available.names), 0, 3)

  # 10.40.0.0/24, .1.0/24, .2.0/24          public (LBs, NAT)
  # 10.40.32.0/19, .64.0/19, .96.0/19       private (nodes + pod IPs)
  public_subnet_cidrs  = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnet_cidrs = [for i in range(3) : cidrsubnet(var.vpc_cidr, 3, i + 1)]
}

module "vpc" {
  source = "../../../modules/vpc"

  name                 = local.name
  cluster_name         = local.name
  cidr                 = var.vpc_cidr
  azs                  = local.azs
  public_subnet_cidrs  = local.public_subnet_cidrs
  private_subnet_cidrs = local.private_subnet_cidrs
  single_nat_gateway   = var.single_nat_gateway
  private_zone_name    = "${var.project}.internal"

  interface_endpoints = var.interface_endpoints # null => module default
}

module "outputs" {
  source = "../../../modules/ssm-outputs"
  prefix = "${local.prefix}/${local.layer}"
  values = {
    vpc_id             = module.vpc.vpc_id
    vpc_cidr           = module.vpc.vpc_cidr
    azs                = jsonencode(module.vpc.azs)
    public_subnet_ids  = jsonencode(module.vpc.public_subnet_ids)
    private_subnet_ids = jsonencode(module.vpc.private_subnet_ids)
    private_zone_id    = module.vpc.private_zone_id
    private_zone_name  = module.vpc.private_zone_name
    nat_public_ips     = jsonencode(module.vpc.nat_public_ips)
  }
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "nat_public_ips" {
  value = module.vpc.nat_public_ips
}
