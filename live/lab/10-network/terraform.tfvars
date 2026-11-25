vpc_cidr = "10.40.0.0/16"

# Cost levers for a throwaway lab (both reduce resilience):
single_nat_gateway  = true
interface_endpoints = []
# interface_endpoints = ["ssm", "ssmmessages", "ec2messages", "sts", "ecr.api", "ecr.dkr"]
