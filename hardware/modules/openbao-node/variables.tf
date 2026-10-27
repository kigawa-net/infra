variable "host" {
  description = "SSH の接続先(ノードの自宅 LAN または管理網のアドレス)。WireGuard のアドレスではない"
  type        = string
}

variable "ssh_user" {
  type    = string
  default = "kigawa"
}

variable "ssh_private_key" {
  type      = string
  sensitive = true
}

variable "sudo_password" {
  type      = string
  sensitive = true
}

variable "node_id" {
  description = "raft の node_id。このノードの識別子(例: bao-02)。retry_join の一覧からは自分を除く"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.node_id))
    error_message = "node_id は小文字・数字・ハイフンのみ。"
  }
}

variable "wg_address" {
  description = "WireGuard 上の IPv4 アドレス(単独、CIDR なし)。listener・api_addr・cluster_addr に使う"
  type        = string

  validation {
    condition     = can(regex("^(\\d{1,3}\\.){3}\\d{1,3}$", var.wg_address))
    error_message = "wg_address は IPv4 アドレス(単独)。CIDR は付けない。"
  }
}

variable "peers" {
  description = "raft の他のノード(retry_join の宛先)。address は WireGuard の IPv4。自分自身が含まれていても無視する"
  type = list(object({
    node_id = string
    address = string
  }))
  default = []
}

variable "openbao_version" {
  description = "固定する OpenBao のバージョン(例: 2.7.2)。latest は使わない"
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.openbao_version))
    error_message = "openbao_version は X.Y.Z 形式で固定すること(latest 不可)。"
  }
}

variable "openbao_deb_sha256" {
  description = "公式の .deb(openbao_<version>_linux_amd64.deb)の SHA256。空のままでは apply できない(precondition)"
  type        = string
  default     = ""

  validation {
    condition     = var.openbao_deb_sha256 == "" || can(regex("^[0-9a-f]{64}$", var.openbao_deb_sha256))
    error_message = "openbao_deb_sha256 は 64 桁の小文字 16 進数、または空。"
  }
}

variable "tls_cert_pem" {
  description = "サーバ証明書(PEM)。外部の CA で発行したもの。bws から渡す"
  type        = string
  sensitive   = true
  default     = ""
}

variable "tls_key_pem" {
  description = "サーバ秘密鍵(PEM)。0600 openbao 所有で配置する"
  type        = string
  sensitive   = true
  default     = ""
}

variable "tls_ca_pem" {
  description = "発行元の CA 証明書(PEM)。ピアの検証に使う(retry_join の leader_ca_cert_file)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "wipe_data_on_failure" {
  description = "true のときだけ、失敗時に /var/lib/openbao を消す(初回構築の失敗からの復旧用)。初期化後の誤削除を防ぐため、既定は false"
  type        = bool
  default     = false
}
