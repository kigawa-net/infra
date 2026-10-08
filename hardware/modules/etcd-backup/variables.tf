variable "host" {
  type = string
}

variable "ssh_user" {
  type = string
}

variable "ssh_private_key" {
  type      = string
  sensitive = true
}

variable "sudo_password" {
  type      = string
  sensitive = true
}

variable "node_name" {
  description = "バックアップの保存先のプレフィックス(R2 の <node_name>/<timestamp>/ になる)"
  type        = string
}

variable "enabled" {
  description = "false のとき、ノードに何も入れない(timer も入れない)。age の公開鍵と R2 の認証情報が揃うまでは false のまま"
  type        = bool
  default     = false
}

variable "age_recipient" {
  description = "age の公開鍵(age1...)。暗号化にだけ使う。秘密鍵はノードに置かず、Bitwarden に保管する"
  type        = string
  default     = ""
}

variable "r2_endpoint" {
  description = "R2 の S3 互換エンドポイント"
  type        = string
  default     = "https://e9f30fd43ef4cc3d46050e34dad5c811.r2.cloudflarestorage.com"
}

variable "r2_bucket" {
  type    = string
  default = "etcd-backup"
}

variable "r2_access_key_id" {
  description = "R2 のアクセスキー ID(etcd-backup バケット限定の Object Read & Write)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "r2_secret_access_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "interval_minutes" {
  description = "スナップショットの間隔(分)"
  type        = number
  default     = 60
}

variable "retention_days" {
  description = "この日数より古い世代を、アップロード後に削除する(ただし、最新の min_keep 世代は残す)"
  type        = number
  default     = 14
}

variable "min_keep" {
  description = "保持期間に関係なく、必ず残す最新の世代数(時計の誤りなどで、全て消えるのを防ぐ)。間隔 60 分なら 48 = 2 日分"
  type        = number
  default     = 48
}

variable "textfile_dir" {
  description = "node_exporter の textfile collector のディレクトリ(成功・失敗のメトリクスを書く)"
  type        = string
  default     = "/var/lib/node_exporter/textfile"
}
