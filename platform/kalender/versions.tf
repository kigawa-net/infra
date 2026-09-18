terraform {
  required_version = ">= 1.6"

  backend "s3" {
    bucket = "infra"
    key    = "platform/kalender/terraform.tfstate"
    region = "auto"
    endpoints = {
      s3 = "https://e9f30fd43ef4cc3d46050e34dad5c811.r2.cloudflarestorage.com"
    }
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_path_style              = true
  }

  required_providers {
    # mcp-growiと同じmrparkers/keycloakを使う。アーカイブ済みだが、この組織で最も新しい
    # 未マージのfomageモジュール(kigawa-net/infra worktree "wobbly-scribbling-raven")でも
    # 引き続きこのプロバイダが使われており、それが現時点で最も新しい採用実績のため踏襲する。
    keycloak = {
      source  = "mrparkers/keycloak"
      version = "~> 4.0"
    }
    # bitwarden-labs/bitwarden-smは非推奨・レジストリから削除済みのため、
    # 後継のbitwarden/bitwarden-secretsを使う(admin-panel/versions.tfと同じ)
    bitwarden-secrets = {
      source  = "bitwarden/bitwarden-secrets"
      version = "~> 1.0"
    }
    # 既存のMicrosoft Entra(Azure AD)アプリ登録のリダイレクトURI/シークレットを管理する。
    # この組織のTerraformでAzureを扱うのは初めてのため、事前にTerraform自動化用の
    # サービスプリンシパル(Application.ReadWrite.All権限)をAzure側で1回だけ手動作成する必要がある。
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }
}

provider "keycloak" {
  client_id = "admin-cli"
  username  = "admin"
  password  = var.keycloak_admin_password
  url       = var.keycloak_url
  realm     = "master"
}

provider "bitwarden-secrets" {
  api_url         = "https://api.bitwarden.com"
  identity_url    = "https://identity.bitwarden.com"
  organization_id = var.bws_organization_id
}

provider "azuread" {
  client_id     = var.azuread_terraform_client_id
  client_secret = var.azuread_terraform_client_secret
  tenant_id     = var.azuread_tenant_id
}
