provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project    = var.project
      Env        = "prod"
      ManagedBy  = "terraform"
      Repository = var.repository
    }
  }
}

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

provider "postgresql" {
  host             = module.rds.address
  port             = module.rds.port
  username         = module.rds.master_username
  password         = module.rds.master_password
  superuser        = false
  sslmode          = "require"
  connect_timeout  = 15
  database         = module.rds.initial_database
  expected_version = "16"
}
