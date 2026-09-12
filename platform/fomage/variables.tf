variable "keycloak_url" {
  description = "Keycloak base URL"
  type        = string
  default     = "https://user.kigawa.net"
}

variable "keycloak_admin_password" {
  description = "Keycloak admin password (injected by run.sh from BWS)"
  type        = string
  sensitive   = true
}

variable "bws_organization_id" {
  description = "Bitwarden Secrets Manager organization ID (same org used by the k8s BitwardenSecret CRDs)"
  type        = string
  default     = "a2b57f3d-6e2b-4467-b499-b31e00bfd804"
}
