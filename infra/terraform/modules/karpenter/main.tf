data "aws_partition" "current" {}
data "aws_region" "current" {}

# IAM, SQS, EventBridge wiring from the EKS module's karpenter submodule.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.24"

  cluster_name = var.cluster_name

  # Use IRSA-style service account.
  enable_irsa            = true
  irsa_oidc_provider_arn = var.oidc_provider_arn

  # Permissions Karpenter uses to inspect the cluster + manage nodes.
  node_iam_role_use_name_prefix   = false
  node_iam_role_name              = "${var.cluster_name}-karpenter-node"
  create_pod_identity_association = false
}

# ── Karpenter Helm install ────────────────────────────────────────────────
resource "helm_release" "karpenter" {
  namespace        = "kube-system"
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_chart_version
  create_namespace = false
  wait             = true

  values = [yamlencode({
    serviceAccount = {
      annotations = {
        "eks.amazonaws.com/role-arn" = module.karpenter.iam_role_arn
      }
    }
    settings = {
      clusterName       = var.cluster_name
      clusterEndpoint   = var.cluster_endpoint
      interruptionQueue = module.karpenter.queue_name
    }
    controller = {
      resources = {
        requests = { cpu = "200m", memory = "256Mi" }
        limits   = { memory = "512Mi" }
      }
    }
    # Tolerate the bootstrap MNG taint so Karpenter itself can run there.
    tolerations = [
      { key = "CriticalAddonsOnly", operator = "Exists" }
    ]
    nodeSelector = {
      "node-pool" = "bootstrap"
    }
  })]
}

# ── Default NodePool + EC2NodeClass ───────────────────────────────────────
# These tell Karpenter what kind of nodes to provision. Bottlerocket AMI ID
# is read from SSM and pinned — Day 2 patching = bump this and re-apply,
# Karpenter's drift detection rotates nodes one at a time honoring PDBs.
data "aws_ssm_parameter" "bottlerocket_ami" {
  name = "/aws/service/bottlerocket/aws-k8s-${var.cluster_version}/x86_64/latest/image_id"
}

resource "kubectl_manifest" "default_node_class" {
  depends_on = [helm_release.karpenter]

  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "default"
    }
    spec = {
      amiFamily = "Bottlerocket"
      amiSelectorTerms = [
        { id = data.aws_ssm_parameter.bottlerocket_ami.value },
      ]
      role = module.karpenter.node_iam_role_name
      subnetSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = var.cluster_name } },
      ]
      securityGroupSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = var.cluster_name } },
      ]
      tags = {
        "karpenter.sh/discovery" = var.cluster_name
        "Project"                = var.project
      }
      blockDeviceMappings = [
        {
          deviceName = "/dev/xvdb"
          ebs = {
            volumeSize          = "50Gi"
            volumeType          = "gp3"
            encrypted           = true
            deleteOnTermination = true
          }
        },
      ]
    }
  })
}

resource "kubectl_manifest" "default_node_pool" {
  depends_on = [kubectl_manifest.default_node_class]

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "default"
    }
    spec = {
      template = {
        metadata = {
          labels = {
            "node-pool" = "default"
          }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          requirements = [
            { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
            { key = "kubernetes.io/os", operator = "In", values = ["linux"] },
            { key = "karpenter.sh/capacity-type", operator = "In", values = var.allow_spot ? ["spot", "on-demand"] : ["on-demand"] },
            { key = "karpenter.k8s.aws/instance-category", operator = "In", values = ["t", "m", "c"] },
            { key = "karpenter.k8s.aws/instance-generation", operator = "Gt", values = ["3"] },
          ]
          expireAfter = "720h" # 30d max node lifetime so security patches catch up
        }
      }
      limits = {
        cpu    = var.cpu_limit
        memory = var.memory_limit
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "30s"
      }
    }
  })
}
