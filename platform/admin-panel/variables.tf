variable "bws_project_id" {
  description = "Bitwarden Secrets Manager project ID (optional)"
  type        = string
  default     = null
}

variable "github_token" {
  description = "GitHub PAT with 'admin:org' (organization secrets) scope, injected by run.sh from BWS"
  type        = string
  sensitive   = true
}
