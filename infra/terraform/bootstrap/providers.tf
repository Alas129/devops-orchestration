provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      ManagedBy   = "terraform"
      Component   = "bootstrap"
      Repository  = var.repository
    }
  }
}
