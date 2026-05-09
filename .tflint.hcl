config {
  format = "compact"
  call_module_type = "local"
  force = false
  disabled_by_default = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.32.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Allow our wrapping convention: per-env composition references modules.
rule "terraform_required_providers" { enabled = true }
rule "terraform_required_version"   { enabled = true }
rule "terraform_unused_declarations" { enabled = true }
rule "terraform_naming_convention"  { enabled = true }
