terraform {
  backend "s3" {
    key     = "nonprod/terraform.tfstate"
    encrypt = true
  }
}
