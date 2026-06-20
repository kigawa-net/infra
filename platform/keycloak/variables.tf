variable "keycloak_url" {
  description = "Keycloak server URL"
  type        = string
  default     = "https://user.kigawa.net"
}

variable "keycloak_admin_username" {
  description = "Keycloak admin username"
  type        = string
  default     = "admin"
}

variable "keycloak_password_secret_id" {
  description = "Bitwarden secret ID for Keycloak admin password"
  type        = string
}
