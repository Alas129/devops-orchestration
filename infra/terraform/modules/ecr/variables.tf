variable "project" {
  description = "Project prefix for repo naming (e.g. 'usf-devops')"
  type        = string
}

variable "repositories" {
  description = "List of repository short names (e.g. ['frontend', 'auth-svc'])"
  type        = list(string)
}

variable "retain_count" {
  description = "How many non-release (git-<sha>) tagged images to keep per repo"
  type        = number
  default     = 30
}

variable "replication_destination_regions" {
  description = "Additional regions to replicate every image to (DR). Empty = no replication."
  type        = list(string)
  default     = []
}
