variable "keycloak_url" {
  description = "Keycloak base URL"
  type        = string
  default     = "https://user.kigawa.net"
}

variable "keycloak_realm" {
  description = "kalenderが使う共有realm(admin-panel等と共用)"
  type        = string
  default     = "kigawa-net"
}

variable "keycloak_admin_password" {
  description = "Keycloak admin password (run.shがBWSから注入する。他モジュールと共用の変数)"
  type        = string
  sensitive   = true
}

variable "bws_organization_id" {
  description = "Bitwarden Secrets Manager organization ID (同じ組織のk8s BitwardenSecret CRDと共用)"
  type        = string
  default     = "a2b57f3d-6e2b-4467-b499-b31e00bfd804"
}

variable "bws_project_id" {
  description = "kalenderのシークレットを格納するBitwarden Secrets ManagerのプロジェクトID"
  type        = string
}

variable "google_idp_client_id" {
  description = <<-EOT
    KeycloakがGoogleへブローカーするための「ウェブアプリケーション」タイプのOAuthクライアントID。
    Google Cloud Consoleで新規作成すること(既存のkalenderアプリが直接使っているSPA向けクライアントは
    流用不可。シークレットを持つ「ウェブアプリケーション」タイプが必要)。
    承認済みのリダイレクトURIに https://user.kigawa.net/realms/kigawa-net/broker/google/endpoint を追加。
  EOT
  type        = string
}

variable "google_idp_client_secret" {
  description = "上記Googleクライアントのシークレット(run.shがBWSから注入)"
  type        = string
  sensitive   = true
}

variable "microsoft_idp_client_id" {
  description = <<-EOT
    KeycloakがMicrosoftへブローカーするための「Web」プラットフォームのアプリケーション(クライアント)ID。
    Azure Portalで、既存のkalenderアプリ登録に「Web」プラットフォームを追加して作成すること
    (既存の「シングルページアプリケーション」プラットフォームはシークレットを持たないため流用不可)。
    リダイレクトURIに https://user.kigawa.net/realms/kigawa-net/broker/microsoft/endpoint を追加。
  EOT
  type        = string
}

variable "microsoft_idp_client_secret" {
  description = "上記MicrosoftクライアントのシークレットVALUE(run.shがBWSから注入)"
  type        = string
  sensitive   = true
}
