variable "fqdn" {
  type        = string
  description = "Fully qualified domain name covered by the cert (e.g. 'dev.calmloop.space'). A wildcard for one level below is added automatically."
}

variable "zone_id" {
  type        = string
  description = "Cloudflare zone ID (output of modules/dns)."
}

variable "additional_sans" {
  type    = list(string)
  default = []
}
