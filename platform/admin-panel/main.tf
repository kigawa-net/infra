resource "random_password" "ci_token" {
  length  = 64
  special = false

  lifecycle {
    ignore_changes = [result]
  }
}

# Looked up by name instead of a hardcoded ID: two guessed project UUIDs both 404'd,
# turns out the issue was the ID (or access to it), not the concept — this data source
# only ever returns projects the CI machine account can actually see, so a lookup miss
# fails with a clear "index out of range" instead of a cryptic API 404.
data "bitwarden-secrets_projects" "all" {}

locals {
  github_app_project_id = [
    for p in data.bitwarden-secrets_projects.all.projects : p.id
    if p.name == "github-app-kigawa-net"
  ][0]
}

resource "bitwarden-secrets_secret" "ci_token" {
  key        = "admin-panel-github-app-ci-token"
  value      = random_password.ci_token.result
  project_id = local.github_app_project_id
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
