resource "random_password" "ci_token" {
  length  = 64
  special = false

  lifecycle {
    ignore_changes = [result]
  }
}

resource "bitwarden-secrets_secret" "ci_token" {
  key   = "admin-panel-github-app-ci-token"
  value = random_password.ci_token.result
  # project_id intentionally omitted: passing var.bws_project_id (default null) here made
  # the provider send an empty string to the API instead of treating it as unset, which
  # fails UUID parsing ("expected length 32 for simple format, found 0"). Omitting the
  # argument entirely avoids that; set a real project UUID here if/when one is needed.
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
