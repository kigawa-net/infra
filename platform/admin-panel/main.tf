resource "random_password" "ci_token" {
  length  = 64
  special = false

  lifecycle {
    ignore_changes = [result]
  }
}

# Two guessed project IDs both 404'd; turned out the project ID itself
# (3f39dcb2-4e04-4c80-bcc4-b3e100e4e27a) was right all along, but nothing
# confirmed the CI machine account could actually see it. Rather than hardcode
# it a third time, read it off the "github-app-kigawa-net" secret (the App's
# private key, same one admin-panel's server reads via GITHUB_APP_PRIVATE_KEY)
# that's known to already live in the right project — if the machine account
# can't read that secret, this data source fails loudly instead of a cryptic
# empty-project_id UUID error downstream.
data "bitwarden-secrets_secret" "github_app_private_key" {
  id = "97b6eba7-6bd2-418d-9d64-b48a007a097a"
}

resource "bitwarden-secrets_secret" "ci_token" {
  key        = "admin-panel-github-app-ci-token"
  value      = random_password.ci_token.result
  project_id = data.bitwarden-secrets_secret.github_app_private_key.project_id
}

# MCP Server用のaudienceとして機能するクライアントを定義
resource "keycloak_openid_client" "mcp_resource" {
  realm_id    = var.keycloak_realm
  client_id   = "https://admin.kigawa.net/mcp"
  name        = "MCP Resource Server"
  enabled     = true
  access_type = "BEARER-ONLY"
}

# MCP Server用のclient scope定義。aud=https://admin.kigawa.net/mcp を
# access tokenへ追加し、admin-panelのRBAC rolesも同時に反映する。
resource "keycloak_openid_client_scope" "mcp_admin_panel" {
  realm_id    = var.keycloak_realm
  name        = "mcp:admin-panel"
  description = "MCP access for admin-panel"
}

# aud に https://admin.kigawa.net/mcp を含めるAudience Mapper
resource "keycloak_openid_audience_protocol_mapper" "mcp_admin_panel_aud" {
  realm_id                 = var.keycloak_realm
  name                     = "MCP audience"
  client_scope_id          = keycloak_openid_client_scope.mcp_admin_panel.id
  included_client_audience = keycloak_openid_client.mcp_resource.client_id
  add_to_id_token          = false
  add_to_access_token      = true
}

# admin-panel client roles (viewer/operator/admin) を access tokenのrolesへ追加
resource "keycloak_openid_group_membership_protocol_mapper" "mcp_admin_panel_roles" {
  realm_id        = var.keycloak_realm
  name            = "admin-panel roles"
  client_scope_id = keycloak_openid_client_scope.mcp_admin_panel.id
  claim_name      = "roles"
}

# CI(kigawa-net/kinfra#348 のcomposite action経由)がadmin-panelの
# GitHub Appブローカーエンドポイントを呼べるよう、同じ値を組織シークレット
# としても登録する。visibilityはこのシークレットを使う2リポジトリに限定。
resource "github_actions_organization_secret" "admin_panel_ci_token" {
  secret_name             = "ADMIN_PANEL_CI_TOKEN"
  visibility              = "selected"
  selected_repository_ids = [1270173867, 1073732523] # admin-panel, kinfra
  plaintext_value         = random_password.ci_token.result
}

# admin-panel#64: CI向けトークン発行の呼び出し元リポジトリ別許可設定(ciTokenPolicy)を
# コードのハードコードから管理画面経由のDB管理に変える。永続化先として専用MariaDBを
# 新規に立てる(root用・admin-panel専用アプリユーザー用の2パスワードをそれぞれ生成)。
resource "random_password" "mariadb_root_password" {
  length  = 32
  special = false

  lifecycle {
    ignore_changes = [result]
  }
}

resource "random_password" "mariadb_app_password" {
  length  = 32
  special = false

  lifecycle {
    ignore_changes = [result]
  }
}

resource "bitwarden-secrets_secret" "mariadb_root_password" {
  key        = "admin-panel-mariadb-root-password"
  value      = random_password.mariadb_root_password.result
  project_id = data.bitwarden-secrets_secret.github_app_private_key.project_id
}

resource "bitwarden-secrets_secret" "mariadb_app_password" {
  key        = "admin-panel-mariadb-app-password"
  value      = random_password.mariadb_app_password.result
  project_id = data.bitwarden-secrets_secret.github_app_private_key.project_id
}
