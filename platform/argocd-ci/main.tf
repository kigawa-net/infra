# argocd-cmは既にkubectl applyで管理されており(admin-panel等の既存
# Terraformモジュールもこのdataキー全体を所有していないため)、
# kubernetes_config_map_v1_dataでこのキーだけを追加所有する
# (server-side apply、他キーには影響しない)。
resource "kubernetes_config_map_v1_data" "argocd_cm_account" {
  metadata {
    name      = "argocd-cm"
    namespace = "argocd"
  }
  data = {
    "accounts.rpgcore-pr-ci" = "apiKey"
  }
  field_manager = "argocd-ci-tf"
  force         = true
}

# argocd-rbac-cmのpolicy.csvは単一キーに全ポリシーがまとまっているため、
# 既存の内容(role:one-admin, role:kigawa-net-dev等)をそのまま残しつつ
# 新しい読み取り専用ロールを追記する形でこのキーを所有する。
resource "kubernetes_config_map_v1_data" "argocd_rbac_cm_policy" {
  metadata {
    name      = "argocd-rbac-cm"
    namespace = "argocd"
  }
  data = {
    "policy.csv" = <<-EOT
      p, role:one-admin, applications, create, one/*, allow
      p, role:one-admin, applications, get, one/*, allow
      p, role:one-admin, applications, override, one/*, allow
      p, role:one-admin, applications, sync, one/*, allow
      p, role:one-admin, applications, update, one/*, allow
      p, role:one-admin, applications, action/*, one/*, allow
      p, role:one-admin, logs, get, one/*, allow
      p, role:one-admin, exec, create, one/*, allow
      p, role:one-admin, projects, get, one, allow

      p, role:kigawa-net-dev, applications, create, kigawa-net/*, allow
      p, role:kigawa-net-dev, applications, get, kigawa-net/*, allow
      p, role:kigawa-net-dev, applications, override, kigawa-net/*, allow
      p, role:kigawa-net-dev, applications, sync, kigawa-net/*, allow
      p, role:kigawa-net-dev, applications, update, kigawa-net/*, allow
      p, role:kigawa-net-dev, applications, action/*, kigawa-net/*, allow
      p, role:kigawa-net-dev, logs, get, kigawa-net/*, allow
      p, role:kigawa-net-dev, projects, get, kigawa-net, allow

      # RpgCore PRプレビュー環境のCIが、デプロイ済みApplicationのhealth
      # statusを読み取ってPRコメントに反映するための読み取り専用ロール。
      p, role:rpgcore-pr-ci, applications, get, one/*, allow

      g, OneServerMC:server, role:one-admin
      g, kigawa-net:dev-team, role:kigawa-net-dev
      g, github@kigawa.net, role:admin
      g, contact@kigawa.net, role:admin
      g, rpgcore-pr-ci, role:rpgcore-pr-ci
    EOT
  }
  field_manager = "argocd-ci-tf"
  force         = true
}

resource "argocd_account_token" "rpgcore_pr_ci" {
  account      = "rpgcore-pr-ci"
  expires_in   = "8760h" # 1年
  renew_before = "720h"  # 残り30日を切ったら更新

  depends_on = [kubernetes_config_map_v1_data.argocd_cm_account]
}

resource "bitwarden-secrets_secret" "rpgcore_pr_ci_token" {
  key        = "argocd-rpgcore-pr-ci-token"
  value      = argocd_account_token.rpgcore_pr_ci.jwt
  project_id = var.bws_project_id
  note       = "RpgCore PRプレビュー環境のCIがArgoCD Applicationのhealth statusを読むための読み取り専用トークン(kigawa-net/infra platform/argocd-ci管理)"
}

# GitHub-hosted runnerはクラスタ内のServiceAccountトークンを使えないため、
# 同じ読み取り専用トークンをActions secretとしても配布する。
resource "github_actions_secret" "argocd_api_token" {
  repository  = "RpgCore"
  secret_name = "ARGOCD_API_TOKEN"
  value       = argocd_account_token.rpgcore_pr_ci.jwt
}

# velocity-pr-discovery(dev.onemc.worldに接続後、/serverコマンドでPRプレビュー
# 環境へ移動するためのVelocityプラグイン)のCIがharbor.kigawa.netにイメージを
# pushできるよう、既存のHarborクレデンシャル(BWS: harbor-user/harbor-pass)を
# Actions secretとして配布する。
data "bitwarden-secrets_secret" "harbor_user" {
  id = "929d361e-e599-4b58-b173-b3e201004d0a"
}

data "bitwarden-secrets_secret" "harbor_pass" {
  id = "13c66d3b-7eb6-4c37-b466-b3e2010057b1"
}

resource "github_actions_secret" "velocity_pr_discovery_harbor_username" {
  repository  = "velocity-pr-discovery"
  secret_name = "HARBOR_USERNAME"
  value       = data.bitwarden-secrets_secret.harbor_user.value
}

resource "github_actions_secret" "velocity_pr_discovery_harbor_password" {
  repository  = "velocity-pr-discovery"
  secret_name = "HARBOR_PASSWORD"
  value       = data.bitwarden-secrets_secret.harbor_pass.value
}
