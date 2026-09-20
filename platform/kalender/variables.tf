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
  description = <<-EOT
    kalenderのシークレットを格納するBitwarden Secrets ManagerのプロジェクトID。
    他モジュール(admin-panel等)と同じ"infra"プロジェクトを流用する
    (`bws project list`で確認済み、このBWS組織にはプロジェクトが1つしか存在しない)。
    プロジェクトIDは機密情報ではないためデフォルト値としてコード管理する。
  EOT
  type        = string
  default     = "3f39dcb2-4e04-4c80-bcc4-b3e100e4e27a"
}

variable "google_idp_client_id" {
  description = <<-EOT
    KeycloakがGoogleへブローカーするための「ウェブアプリケーション」タイプのOAuthクライアントID
    (kalender-web)。承認済みのリダイレクトURIに
    https://user.kigawa.net/realms/kigawa-net/broker/google/endpoint を追加済み。
    クライアントIDは機密情報ではないためデフォルト値としてコード管理する。
  EOT
  type        = string
  default     = "441586545378-br8bjafc1b1bgsis0r9s4d3a02ij9ec0.apps.googleusercontent.com"
}

variable "google_idp_client_secret" {
  description = "上記Googleクライアントのシークレット(run.shがBWSから注入)"
  type        = string
  sensitive   = true
}

variable "azuread_tenant_id" {
  description = <<-EOT
    Terraform自動化用サービスプリンシパルおよびkalenderアプリ登録が実際に所属する
    AzureADテナントの実テナントID(GUID)。kalenderの既存MSAL/Web実装がエンドユーザーの
    サインインに使っているマルチテナントエンドポイント"common"とは別物(あちらはOAuth認可
    エンドポイントのエイリアスであり、azureadプロバイダ自体の認証には使えない)。
    クライアントID/テナントIDは機密情報ではないためデフォルト値としてコード管理する。
  EOT
  type        = string
  default     = "8f95fe14-719d-4d3e-bb86-1aed5bafd1d9"
}

variable "azuread_terraform_client_id" {
  description = <<-EOT
    このTerraform自身がMicrosoft Entraアプリ登録を操作するための、専用サービスプリンシパル
    "kalender-terraform-automation"のアプリケーション(クライアント)ID。
    Application.ReadWrite.All権限(アプリケーション権限、管理者の同意済み)を持つ。
    認証はクライアントシークレットではなく証明書(client_certificate)を使う。
    クライアントID/テナントIDは機密情報ではないためデフォルト値としてコード管理する。
  EOT
  type        = string
  default     = "e4bf9241-cae9-41e6-9784-6b37e5d467eb"
}

variable "azuread_terraform_client_certificate" {
  description = <<-EOT
    上記Terraform自動化用サービスプリンシパルの認証用証明書(PFX形式をBase64エンコードした文字列)。
    公開鍵(.cer/.pem)はAzure Portalの当該アプリ登録の「証明書とシークレット」→「証明書」に
    アップロードし、秘密鍵を含むPFXファイルをBase64エンコードしてBWSに保存、run.shから注入すること。
  EOT
  type        = string
  sensitive   = true
}

variable "azuread_terraform_client_certificate_password" {
  description = "上記PFXファイルのパスワード(run.shがBWSから注入)。パスワード無しで作成した場合は空文字列"
  type        = string
  sensitive   = true
  default     = ""
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
