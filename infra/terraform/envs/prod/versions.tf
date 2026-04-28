terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
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
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "~> 1.23"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
