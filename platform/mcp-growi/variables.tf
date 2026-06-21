variable "keycloak_url" {
  description = "Keycloak base URL"
  type        = string
  default     = "https://user.kigawa.net"
}

variable "keycloak_realm" {
  description = "Keycloak realm for mcp-growi"
  type        = string
  default     = "one"
}

variable "keycloak_admin_password" {
  description = "Keycloak admin password (injected by run.sh from BWS)"
  type        = string
  sensitive   = true
}

variable "bws_project_id" {
  description = "Bitwarden Secrets Manager project ID (optional)"
  type        = string
  default     = null
}
