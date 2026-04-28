# Partial backend config — bucket/table/region are filled in via
# `terraform init -backend-config=backend.hcl` (kept out of VCS)
# OR by overriding with the values from the bootstrap output.
terraform {
  backend "s3" {
    key     = "_shared/terraform.tfstate"
    encrypt = true
  }
}
