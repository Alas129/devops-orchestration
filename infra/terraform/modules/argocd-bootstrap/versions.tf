terraform {
  required_version = ">= 1.7.0"
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.32"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
  }
}
