resource "cloudflare_r2_bucket" "kaft" {
  account_id = var.account_id
  name       = "kaft"
  location   = "APAC"
}

resource "cloudflare_r2_bucket" "kaft_stg" {
  account_id = var.account_id
  name       = "kaft-stg"
  location   = "APAC"
}

resource "cloudflare_r2_bucket" "kaft_dev" {
  account_id = var.account_id
  name       = "kaft-dev"
  location   = "APAC"
}

# etcd の定期スナップショットの保存先 (issue #189)。クラスターの外に置く。
# スナップショットは、Secret を含むため、age の公開鍵で暗号化してから置く。
# 書き込み用の R2 トークンは、このバケット限定(Object Read & Write)で、Cloudflare のダッシュボードで作る。
# 保持期間の管理は、cloudflare プロバイダ v4 に R2 のライフサイクルのリソースが無いため、
# バックアップのスクリプトが、アップロード後に古いものを削除する。
resource "cloudflare_r2_bucket" "etcd_backup" {
  account_id = var.account_id
  name       = "etcd-backup"
  location   = "APAC"
}
