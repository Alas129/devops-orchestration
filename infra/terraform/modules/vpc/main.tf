data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # /16 split into 3 subnet groups × 3 AZ × /20:
  #   public  : 10.x.0.0/20, 10.x.16.0/20, 10.x.32.0/20
  #   private : 10.x.48.0/20, 10.x.64.0/20, 10.x.80.0/20
  #   intra   : 10.x.96.0/20, 10.x.112.0/20, 10.x.128.0/20
  public_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 3)]
  intra_subnets   = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 6)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${var.project}-${var.env}"
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets
  intra_subnets   = local.intra_subnets

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway
  enable_dns_hostnames   = true
  enable_dns_support     = true

  enable_flow_log                      = true
  create_flow_log_cloudwatch_iam_role  = true
  create_flow_log_cloudwatch_log_group = true
  flow_log_max_aggregation_interval    = 60

  # Tags required by AWS Load Balancer Controller and Karpenter for
  # subnet auto-discovery.
  public_subnet_tags = {
    "kubernetes.io/role/elb"                          = "1"
    "kubernetes.io/cluster/${var.cluster_name}"       = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"                 = "1"
    "kubernetes.io/cluster/${var.cluster_name}"       = "shared"
    "karpenter.sh/discovery"                          = var.cluster_name
  }
}
