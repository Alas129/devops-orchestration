provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project    = var.project
      Env        = "nonprod"
      ManagedBy  = "terraform"
      Repository = var.repository
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# Pull shared outputs (Route53 zone, ECR ARNs, GitHub OIDC roles)
data "terraform_remote_state" "shared" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "_shared/terraform.tfstate"
    region = var.region
  }
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
  load_config_file       = false
}

# postgresql provider removed — DB role management migrated to a K8s Job
# (see gitops/platform/db-bootstrap/). RDS is on private subnets so a
# Terraform provider running from a GHA runner outside the VPC cannot
# reach it; in-cluster Job is the standard pattern.
