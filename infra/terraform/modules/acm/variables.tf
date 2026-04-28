variable "fqdn" {
  type        = string
  description = "Fully qualified domain name covered by the cert (e.g. 'dev.usfdevops.example.com'). A wildcard for one level below is added automatically."
}

variable "zone_id" {
  type        = string
  description = "Route53 hosted zone ID"
}

variable "additional_sans" {
  type    = list(string)
  default = []
}
