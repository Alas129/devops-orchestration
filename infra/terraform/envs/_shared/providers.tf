provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project    = var.project
      ManagedBy  = "terraform"
      Component  = "_shared"
      Repository = var.repository
    }
  }
}

provider "cloudflare" {
  # Reads CLOUDFLARE_API_TOKEN (or TF_VAR_cloudflare_api_token via the
  # cloudflare_api_token variable). Don't set inline — keep tokens out of state.
  api_token = var.cloudflare_api_token
}
