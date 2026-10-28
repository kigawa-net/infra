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

variable "enabled" {
  description = "false のとき、ホストに何も入れない(timer も入れない)。B2・age・AppRole の値が揃うまでは false のまま"
  type        = bool
  default     = false
}

variable "b2_endpoint" {
  description = "Backblaze B2 の S3 互換エンドポイント(例: https://s3.us-west-004.backblazeb2.com)。バケットと同じリージョンを指す"
  type        = string
  default     = ""

  validation {
    condition     = var.b2_endpoint == "" || can(regex("^https://s3\\.[a-z0-9-]+\\.backblazeb2\\.com$", var.b2_endpoint))
    error_message = "b2_endpoint は https://s3.<region>.backblazeb2.com の形式。"
  }
}

variable "b2_region" {
  description = "署名(SigV4)のリージョン。空なら b2_endpoint のホスト名から導く(両方を指定したら、一致が検証される)"
  type        = string
  default     = ""

  validation {
    condition     = var.b2_region == "" || can(regex("^[a-z0-9-]+$", var.b2_region))
    error_message = "b2_region は英小文字・数字・ハイフン(例: us-west-004)。"
  }
}

variable "b2_bucket" {
  description = "Object Lock を有効にした B2 バケット(README の手順で作る)"
  type        = string
  default     = "openbao-backup"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{2,62}$", var.b2_bucket))
    error_message = "b2_bucket は、B2 のバケット名(小文字・数字・ハイフン)。"
  }
}

variable "b2_access_key_id" {
  description = "B2 のアプリケーションキー ID。このバケット限定、writeFiles / writeFileRetentions / readFiles のみ。deleteFiles と bypassGovernance は付けない(README 参照)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "b2_secret_access_key" {
  description = "B2 のアプリケーションキーの secret"
  type        = string
  sensitive   = true
  default     = ""
}

variable "age_recipient" {
  description = "age の公開鍵(age1...)。暗号化にだけ使う。このバックアップ専用の鍵(etcd-backup と共有しない)。秘密鍵は、ホストに置かない"
  type        = string
  default     = ""

  validation {
    condition     = var.age_recipient == "" || can(regex("^age1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{58}$", var.age_recipient))
    error_message = "age_recipient は age1 で始まる公開鍵(62 文字)。"
  }
}

variable "bao_endpoints" {
  description = "スナップショットを取る OpenBao のエンドポイント。順に試し、最初に成功したものを使う(アクティブノードが応答する)"
  type        = list(string)
  default     = []
}

variable "approle_role_id" {
  description = "バックアップ用の AppRole の role_id(/etc/openbao-backup/role_id、root のみ読める)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "approle_secret_id" {
  description = "バックアップ用の AppRole の secret_id(/etc/openbao-backup/secret_id、root のみ読める)。policy は sys/storage/raft/snapshot の read のみ"
  type        = string
  sensitive   = true
  default     = ""
}

variable "hosts_entries" {
  description = "実行ホストの /etc/hosts の管理ブロックに入れる名前解決。bao ノードの FQDN を、EasyTier の overlay のアドレスに向ける"
  type = list(object({
    fqdn    = string
    address = string
  }))
  default = []
}

variable "interval_minutes" {
  description = "実行の間隔(分)。6h の世代は、この間隔ごとに 1 つ作られる"
  type        = number
  default     = 360

  validation {
    condition     = var.interval_minutes >= 60 && var.interval_minutes <= 1440
    error_message = "interval_minutes は 60 から 1440 の間。"
  }
}

variable "object_lock_mode" {
  description = "Object Lock のモード。最初の導入は GOVERNANCE(誤りのときに、管理者が戻せる)。運用が固まったら COMPLIANCE"
  type        = string
  default     = "GOVERNANCE"

  validation {
    condition     = contains(["COMPLIANCE", "GOVERNANCE"], var.object_lock_mode)
    error_message = "object_lock_mode は COMPLIANCE か GOVERNANCE。"
  }
}

variable "healthcheck_url" {
  description = "外部の死活監視(dead-man's switch)の ping URL。空なら送らない。成功で URL に、失敗で URL/fail に送る"
  type        = string
  sensitive   = true
  default     = ""
}

variable "textfile_dir" {
  description = "node_exporter の textfile collector のディレクトリ(成功・失敗のメトリクスを書く)"
  type        = string
  default     = "/var/lib/node_exporter/textfile"
}

variable "snapshot_base" {
  description = "平文のスナップショットを置く作業ディレクトリ。tmpfs(RAM)であること。systemd の RuntimeDirectory と一致させる"
  type        = string
  default     = "/run/openbao-backup"
}
