# Copy to terraform.tfvars (which is .gitignored) and fill in.
# `cloudflare_api_token` is set via env var TF_VAR_cloudflare_api_token,
# NOT via this file (keep it out of any tfvars file that might leak).
domain_name = "calmloop.space"
repository  = "Alas129/devops-orchestration"
