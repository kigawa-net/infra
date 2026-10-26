variable "enabled" {
  description = "false(既定)のときは、何も作らず、Bitwarden にも触れない。実機に適用する準備ができてから true にする"
  type        = bool
  default     = false
}

variable "host" {
  description = "bao-01 の SSH の接続先(自宅 LAN または管理網のアドレス)。未設定のままにしている(enabled = true のとき必須)"
  type        = string
  default     = ""
}

variable "ssh_user" {
  type    = string
  default = "kigawa"
}

variable "ssh_key_bitwarden_id" {
  description = "SSH 秘密鍵の bws の ID(k8s-worker1 と同じ鍵)"
  type        = string
  default     = "0393671f-6ef0-4650-be98-b364013f8644"
}

variable "sudo_password_bitwarden_id" {
  description = "sudo パスワードの bws の ID(k8s-worker1 と同じ)"
  type        = string
  default     = "52b44d60-7cab-429f-929a-b4340139b6d8"
}

variable "tls_cert_bitwarden_id" {
  description = "サーバ証明書(PEM)の bws の ID。外部の CA で発行したもの。未設定のままにしている"
  type        = string
  default     = ""
}

variable "tls_key_bitwarden_id" {
  description = "サーバ秘密鍵(PEM)の bws の ID。未設定のままにしている"
  type        = string
  default     = ""
}

variable "tls_ca_bitwarden_id" {
  description = "発行元の CA 証明書(PEM)の bws の ID。未設定のままにしている"
  type        = string
  default     = ""
}

variable "node_id" {
  description = "raft の node_id"
  type        = string
  default     = "bao-01"
}

variable "wg_address" {
  description = "bao-01 の WireGuard 上の IPv4 アドレス(単独)。未設定のままにしている(WireGuard の /32 ピアの割り当てと合わせて決める)"
  type        = string
  default     = ""
}

variable "peers" {
  description = "他の bao ノード(retry_join 先)。bao-02 / bao-03 の node_id と WireGuard の IPv4。未設定のままにしている"
  type = list(object({
    node_id = string
    address = string
  }))
  default = []
}

variable "openbao_version" {
  description = "固定する OpenBao のバージョン(X.Y.Z)。latest は使わない"
  type        = string
  default     = "2.1.0"
}

variable "openbao_deb_sha256" {
  description = "公式の .deb の SHA256。公式の checksum を確認してから設定する。未設定のままにしている"
  type        = string
  default     = ""
}

variable "wipe_data_on_failure" {
  description = "true のときだけ、失敗時に /var/lib/openbao を消す(初回構築の失敗からの復旧用)。既定 false"
  type        = bool
  default     = false
}
