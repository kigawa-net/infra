variable "keycloak_url" {
  description = "Keycloak base URL"
  type        = string
  default     = "https://user.kigawa.net"
}

variable "keycloak_realm" {
  description = "opencode.kigawa.net のログインに使う realm(litellm-api と同じ develop)"
  type        = string
  default     = "develop"
}

variable "keycloak_admin_password" {
  description = "Keycloak admin password (run.sh が BWS から注入する。他モジュールと共用の変数)"
  type        = string
  sensitive   = true
}

variable "bws_organization_id" {
  description = "Bitwarden Secrets Manager organization ID (k8s の BitwardenSecret と共用)"
  type        = string
  default     = "a2b57f3d-6e2b-4467-b499-b31e00bfd804"
}

variable "bws_project_id" {
  description = "シークレットを格納する BWS のプロジェクト ID(\"infra\"。kalender 等と共用)"
  type        = string
  default     = "3f39dcb2-4e04-4c80-bcc4-b3e100e4e27a"
}

variable "opencode_origin" {
  description = "OpenCode の公開オリジン"
  type        = string
  default     = "https://opencode.kigawa.net"
}
