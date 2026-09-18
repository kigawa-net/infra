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

variable "azuread_tenant_id" {
  description = "kalenderのMicrosoft Entraアプリ登録が所属するテナントID"
  type        = string
  default     = "common" # 既存のMSAL/Web実装がマルチテナント"common"を使っているため合わせる
}

variable "azuread_terraform_client_id" {
  description = <<-EOT
    このTerraform自身がMicrosoft Entraアプリ登録を操作するための、専用サービスプリンシパルの
    アプリケーション(クライアント)ID。Azure Portalで「Terraform automation」等の名前で
    Application.ReadWrite.All権限(アプリケーション権限、管理者の同意が必要)を持つ
    アプリ登録を一度だけ手動作成し、そのIDをrun.sh経由でBWSから注入すること。
  EOT
  type        = string
}

variable "azuread_terraform_client_secret" {
  description = "上記Terraform自動化用サービスプリンシパルのクライアントシークレット(run.shがBWSから注入)"
  type        = string
  sensitive   = true
}

variable "microsoft_kalender_app_client_id" {
  description = <<-EOT
    kalenderが既に使っているMicrosoft Entraアプリ登録のアプリケーション(クライアント)ID。
    Keycloak側のMicrosoft IdPブローカー用クライアントID・シークレットはこのアプリ登録に
    "Web"プラットフォームを追加してTerraformが生成するため、Google IdPと異なり
    別途Bitwardenへ手動保存する必要はない。
  EOT
  type        = string
  default     = "3b5392c1-34fe-447b-a09f-ae8144d7564a"
}
