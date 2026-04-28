module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id                   = var.vpc_id
  subnet_ids               = var.private_subnet_ids
  control_plane_subnet_ids = var.intra_subnet_ids

  cluster_endpoint_public_access = true
  cluster_endpoint_public_access_cidrs = var.public_access_cidrs

  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    coredns                = { most_recent = true }
    eks-pod-identity-agent = { most_recent = true }
    kube-proxy             = { most_recent = true }
    vpc-cni = {
      most_recent              = true
      service_account_role_arn = module.vpc_cni_irsa.iam_role_arn
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  cluster_enabled_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]

  # Bootstrap node group: just enough capacity to host Karpenter, ArgoCD,
  # CoreDNS, kube-proxy, vpc-cni. Everything else runs on Karpenter-managed
  # nodes so AMI rotation flows through Karpenter drift detection.
  eks_managed_node_groups = {
    bootstrap = {
      ami_type       = "BOTTLEROCKET_x86_64"
      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"

      min_size     = 2
      desired_size = 2
      max_size     = 3

      # Taint so workloads don't accidentally land here. Karpenter,
      # CoreDNS, ArgoCD, etc. tolerate it explicitly.
      taints = {
        bootstrap = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }

      labels = {
        "node-pool" = "bootstrap"
      }
    }
  }

  # Karpenter discovery tag applied here so the EC2NodeClass can target this
  # security group. Mirror in subnets via the vpc module.
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}

# IRSA for vpc-cni (managed by EKS via the addon) and EBS CSI.
module "vpc_cni_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name             = "${var.cluster_name}-vpc-cni"
  attach_vpc_cni_policy = true
  vpc_cni_enable_ipv4   = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node"]
    }
  }
}

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name             = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}
