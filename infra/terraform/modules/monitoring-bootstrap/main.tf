# Self-hosted observability: Prometheus + Alertmanager + Grafana + Loki +
# Promtail. Grafana is locked to GitHub OAuth (no local accounts).

resource "kubernetes_namespace_v1" "monitoring" {
  metadata { name = "monitoring" }
}

# ── ExternalSecret: Grafana GitHub OAuth client ──────────────────────────
# Expects SSM SecureString params at:
#   /devops/grafana/github/client_id
#   /devops/grafana/github/client_secret
resource "kubectl_manifest" "grafana_github_oauth_external_secret" {
  depends_on = [kubernetes_namespace_v1.monitoring]

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "grafana-github-oauth"
      namespace = "monitoring"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "aws-ssm", kind = "ClusterSecretStore" }
      target = {
        name           = "grafana-github-oauth"
        creationPolicy = "Owner"
      }
      data = [
        { secretKey = "client_id",     remoteRef = { key = "/devops/grafana/github/client_id" } },
        { secretKey = "client_secret", remoteRef = { key = "/devops/grafana/github/client_secret" } },
      ]
    }
  })
}

# ── ExternalSecret: Alertmanager Slack webhook + SES SMTP creds ──────────
resource "kubectl_manifest" "alertmanager_secrets_external_secret" {
  depends_on = [kubernetes_namespace_v1.monitoring]

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "alertmanager-secrets"
      namespace = "monitoring"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "aws-ssm", kind = "ClusterSecretStore" }
      target = {
        name           = "alertmanager-secrets"
        creationPolicy = "Owner"
      }
      data = [
        { secretKey = "slack_webhook_url", remoteRef = { key = "/devops/alertmanager/slack_webhook_url" } },
        { secretKey = "smtp_username",     remoteRef = { key = "/devops/alertmanager/smtp_username" } },
        { secretKey = "smtp_password",     remoteRef = { key = "/devops/alertmanager/smtp_password" } },
      ]
    }
  })
}

# ── kube-prometheus-stack ─────────────────────────────────────────────────
resource "helm_release" "kube_prometheus_stack" {
  depends_on = [
    kubectl_manifest.grafana_github_oauth_external_secret,
    kubectl_manifest.alertmanager_secrets_external_secret,
  ]

  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prom_chart_version
  wait       = true
  timeout    = 600

  values = [yamlencode({
    crds = { enabled = true }

    grafana = {
      adminUser     = "admin"
      adminPassword = "" # we disable the admin login below
      defaultDashboardsTimezone = "browser"

      "grafana.ini" = {
        server = {
          root_url = "https://grafana.${var.subdomain}.${var.domain_name}"
          serve_from_sub_path = false
        }
        auth = {
          disable_login_form     = true
          disable_signout_menu   = false
          oauth_auto_login       = true
          oauth_allow_insecure_email_lookup = false
        }
        "auth.basic" = {
          enabled = false
        }
        "auth.anonymous" = {
          enabled = false
        }
        "auth.github" = {
          enabled               = true
          allow_sign_up         = true
          scopes                = "user:email,read:org"
          auth_url              = "https://github.com/login/oauth/authorize"
          token_url             = "https://github.com/login/oauth/access_token"
          api_url               = "https://api.github.com/user"
          allowed_organizations = var.grafana_allowed_github_orgs
          # client_id and client_secret come from envFromSecret below
        }
        users = {
          # Brand-new users can read; admin promotion is via GitHub team.
          auto_assign_org      = true
          auto_assign_org_role = "Viewer"
        }
      }

      env = {
        # Grafana reads GF_AUTH_GITHUB_CLIENT_ID and GF_AUTH_GITHUB_CLIENT_SECRET.
      }
      envValueFrom = {
        GF_AUTH_GITHUB_CLIENT_ID = {
          secretKeyRef = { name = "grafana-github-oauth", key = "client_id" }
        }
        GF_AUTH_GITHUB_CLIENT_SECRET = {
          secretKeyRef = { name = "grafana-github-oauth", key = "client_secret" }
        }
      }

      ingress = {
        enabled          = true
        ingressClassName = "alb"
        hosts            = ["grafana.${var.subdomain}.${var.domain_name}"]
        annotations = {
          "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
          "alb.ingress.kubernetes.io/target-type"      = "ip"
          "alb.ingress.kubernetes.io/listen-ports"     = jsonencode([{ HTTPS = 443 }])
          "alb.ingress.kubernetes.io/certificate-arn"  = var.certificate_arn
          "alb.ingress.kubernetes.io/ssl-policy"       = "ELBSecurityPolicy-TLS13-1-2-2021-06"
          "alb.ingress.kubernetes.io/healthcheck-path" = "/api/health"
          "external-dns.alpha.kubernetes.io/hostname"  = "grafana.${var.subdomain}.${var.domain_name}"
        }
      }

      sidecar = {
        dashboards = { enabled = true, label = "grafana_dashboard" }
        datasources = { enabled = true, label = "grafana_datasource" }
      }

      additionalDataSources = [
        {
          name      = "Loki"
          type      = "loki"
          url       = "http://loki-stack.monitoring.svc.cluster.local:3100"
          access    = "proxy"
          isDefault = false
        },
      ]
    }

    prometheus = {
      prometheusSpec = {
        retention = "10d"
        storageSpec = {
          volumeClaimTemplate = {
            spec = {
              accessModes = ["ReadWriteOnce"]
              resources = { requests = { storage = "30Gi" } }
              storageClassName = "gp3"
            }
          }
        }
        # Auto-discover ServiceMonitors created by app charts in any namespace.
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        ruleSelectorNilUsesHelmValues           = false
      }
    }

    alertmanager = {
      alertmanagerSpec = {
        secrets = ["alertmanager-secrets"]
      }
      config = {
        global = {
          resolve_timeout = "5m"
          smtp_from       = var.alert_email_from
          smtp_smarthost  = "${var.smtp_host}:${var.smtp_port}"
          smtp_auth_username_file = "/etc/alertmanager/secrets/alertmanager-secrets/smtp_username"
          smtp_auth_password_file = "/etc/alertmanager/secrets/alertmanager-secrets/smtp_password"
          smtp_require_tls        = true
        }
        route = {
          receiver        = "default"
          group_by        = ["alertname", "namespace", "severity"]
          group_wait      = "30s"
          group_interval  = "5m"
          repeat_interval = "12h"
          routes = [
            { matchers = ["severity = critical"], receiver = "critical" },
          ]
        }
        receivers = [
          {
            name = "default"
            slack_configs = [{
              api_url_file = "/etc/alertmanager/secrets/alertmanager-secrets/slack_webhook_url"
              channel      = var.slack_channel
              send_resolved = true
              title        = "{{ .CommonLabels.alertname }}"
              text         = "{{ range .Alerts }}{{ .Annotations.summary }}\n{{ .Annotations.description }}\n{{ end }}"
            }]
          },
          {
            name = "critical"
            slack_configs = [{
              api_url_file = "/etc/alertmanager/secrets/alertmanager-secrets/slack_webhook_url"
              channel      = var.slack_channel
              send_resolved = true
              title        = "[CRITICAL] {{ .CommonLabels.alertname }}"
              text         = "{{ range .Alerts }}{{ .Annotations.summary }}\n{{ .Annotations.description }}\n{{ end }}"
            }]
            email_configs = [{
              to            = var.alert_email_to
              send_resolved = true
            }]
          },
        ]
      }
    }

    nodeExporter = { enabled = true }
    kubeStateMetrics = { enabled = true }
  })]
}

# ── Loki + Promtail ────────────────────────────────────────────────────────
resource "helm_release" "loki_stack" {
  depends_on = [helm_release.kube_prometheus_stack]

  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name
  name       = "loki-stack"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki-stack"
  version    = var.loki_chart_version
  wait       = true
  timeout    = 600

  values = [yamlencode({
    loki = {
      enabled = true
      persistence = {
        enabled      = true
        size         = "20Gi"
        storageClassName = "gp3"
      }
      config = {
        table_manager = {
          retention_deletes_enabled = true
          retention_period          = "168h" # 7d
        }
      }
    }
    promtail = {
      enabled = true
    }
    grafana = {
      enabled = false # using grafana from kube-prometheus-stack
    }
  })]
}
