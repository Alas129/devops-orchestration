# ArgoCD installation + the root "app-of-apps" Application that points at
# the gitops/ tree in this repo. After this applies once, all further changes
# (new microservices, image bumps, env overlays) flow through Git, not TF.

resource "helm_release" "argocd" {
  namespace        = "argocd"
  create_namespace = true
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  wait             = true

  # NB: The ingress is defined as a separate resource below (using an
  # Ingress with ALB annotations) rather than via the chart's ingress block,
  # so we have full control over the ALB annotations.
  values = [yamlencode({
    global = {
      tolerations = [
        { key = "CriticalAddonsOnly", operator = "Exists" }
      ]
      nodeSelector = {
        "node-pool" = "bootstrap"
      }
    }
    configs = {
      params = {
        # ArgoCD UI runs behind an ALB that does TLS termination.
        "server.insecure" = true
      }
      cm = {
        # Enable status badges and webhook annotations
        "statusbadge.enabled" = "true"
        # Optional: link out to GitHub repo
        "url" = "https://argocd.${var.subdomain}.${var.domain_name}"
      }
      rbac = {
        "policy.default" = "role:readonly"
        "policy.csv" = <<-EOT
          g, ${var.admin_github_org}:admins, role:admin
        EOT
      }
    }
    server = {
      ingress = { enabled = false } # we manage Ingress separately below
      extraArgs = ["--insecure"]
    }
    repoServer = {
      # so it can pull this repo if it's private
    }
    # Cosign verification can be enabled later for self-managed GitOps repo
  })]
}

# Ingress for the ArgoCD UI/CLI. Uses the cluster's wildcard ACM cert.
resource "kubernetes_ingress_v1" "argocd" {
  depends_on = [helm_release.argocd]

  metadata {
    name      = "argocd-server"
    namespace = "argocd"
    annotations = {
      "kubernetes.io/ingress.class"                  = "alb"
      "alb.ingress.kubernetes.io/scheme"             = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"        = "ip"
      "alb.ingress.kubernetes.io/listen-ports"       = jsonencode([{ HTTPS = 443 }])
      "alb.ingress.kubernetes.io/certificate-arn"    = var.certificate_arn
      "alb.ingress.kubernetes.io/ssl-policy"         = "ELBSecurityPolicy-TLS13-1-2-2021-06"
      "alb.ingress.kubernetes.io/backend-protocol"   = "HTTP"
      "alb.ingress.kubernetes.io/healthcheck-path"   = "/healthz"
      "external-dns.alpha.kubernetes.io/hostname"    = "argocd.${var.subdomain}.${var.domain_name}"
    }
  }

  spec {
    rule {
      host = "argocd.${var.subdomain}.${var.domain_name}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "argocd-server"
              port { number = 80 }
            }
          }
        }
      }
    }
  }
}

# Root app-of-apps. Points at gitops/argocd/applications/<env>/.
resource "kubectl_manifest" "root_app_of_apps" {
  depends_on = [helm_release.argocd]

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "root"
      namespace = "argocd"
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.gitops_repo_url
        targetRevision = var.gitops_revision
        path           = "gitops/argocd/applications/${var.cluster_app_dir}"
        directory = {
          recurse = true
          include = "*.yaml"
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "ServerSideApply=true",
        ]
      }
    }
  })
}
