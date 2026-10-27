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
  description = "raft の他のノード(retry_join の宛先と /etc/hosts の対応)。fqdn は証明書の名前、address は WireGuard の IPv4。自分自身が含まれていても無視する(fqdn で判定する)"
  type = list(object({
    fqdn    = string
    address = string
  }))
  default = []

  validation {
    condition = alltrue([
      for p in var.peers :
      can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", p.fqdn)) &&
      can(regex("^(\\d{1,3}\\.){3}\\d{1,3}$", p.address))
    ])
    error_message = "peers の fqdn は小文字の FQDN、address は WireGuard の IPv4(単独)。"
  }
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

variable "fqdn" {
  description = "このノードの証明書の名前(例: bao-02.kigawa.net)。ノード自身が certbot で Let's Encrypt から DNS-01 により発行する。/etc/hosts で WireGuard の IP に向ける"
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.fqdn))
    error_message = "fqdn は小文字の FQDN(例: bao-02.kigawa.net)。"
  }
}

variable "cloudflare_api_token" {
  description = "Cloudflare の API トークン(kigawa.net ゾーンの Zone:DNS:Edit のみ。Cloudflare 側で、クライアント IP を bao ノードの公開 IP に制限する)。ノードの /etc/letsencrypt/cloudflare.ini に 0600 root で置く。sensitive だが、SSH 鍵と同じく Terraform の state には入る"
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]+$", var.cloudflare_api_token))
    error_message = "cloudflare_api_token は英数字・_・- のみ(ini に書くため、他の文字は受け付けない)。値はエラーに含めない。"
  }
}

variable "acme_email" {
  description = "Let's Encrypt のアカウントの連絡先メール。空のときは --register-unsafely-without-email で登録する(期限切れなどの通知が届かない)。実在のアドレスは、既定値に書かず、呼び出し側から渡す"
  type        = string
  default     = ""

  validation {
    condition     = var.acme_email == "" || can(regex("^[^@\\s'\"]+@[^@\\s'\"]+\\.[^@\\s'\"]+$", var.acme_email))
    error_message = "acme_email は空、またはメールアドレス形式(引用符や空白は不可)。"
  }
}

variable "acme_staging" {
  description = "true のとき、Let's Encrypt の staging を使う(試験用。ブラウザ等では信頼されない証明書。レート制限が緩い)。切り替えると、既存の証明書を消して発行し直す"
  type        = bool
  default     = false
}

variable "wipe_data_on_failure" {
  description = "true のときだけ、失敗時に /var/lib/openbao を消す(初回構築の失敗からの復旧用)。初期化後の誤削除を防ぐため、既定は false"
  type        = bool
  default     = false
}
