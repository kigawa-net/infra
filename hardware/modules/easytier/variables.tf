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

variable "easytier_version" {
  description = "導入する EasyTier のバージョン(例: 2.7.0。`v` は付けない)。採用バージョンは未確定のため既定値は置かない。Relay 切替と Direct への復帰を、このバージョンで実測してから固定すること(docs/network-vpn-architecture-design.md §4.1)"
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.easytier_version))
    error_message = "easytier_version は 2.7.0 のような形式で指定する(`v` は付けない)。"
  }
}

variable "easytier_arch" {
  description = "配布 zip のアーキテクチャ(easytier-linux-<arch>-v<version>.zip の <arch>)"
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "aarch64"], var.easytier_arch)
    error_message = "easytier_arch は x86_64 か aarch64。"
  }
}

variable "easytier_sha256" {
  description = "配布 zip(easytier_arch に対応するもの)の SHA-256。ダウンロード後に照合し、一致しなければ何も入れずに失敗する。リリースページの値ではなく、自分でダウンロードして計算した値を入れること"
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.easytier_sha256))
    error_message = "easytier_sha256 は小文字 16 進 64 文字。"
  }
}

variable "instance_name" {
  description = "EasyTier のインスタンス名(TUN インターフェース名にも使われる)"
  type        = string
  default     = "kigawa-net"
}

variable "network_name" {
  description = "EasyTier のネットワーク名"
  type        = string
}

variable "network_secret" {
  description = "EasyTier のネットワーク Secret。Bitwarden から取得して渡す(Git に平文で置かない)。ノード上では 0600 の設定ファイルにだけ書く"
  type        = string
  sensitive   = true
}

variable "overlay_address" {
  description = "このノードの Overlay アドレス(CIDR 付き。例: 10.250.0.11/24)"
  type        = string

  validation {
    condition     = can(cidrhost(var.overlay_address, 0))
    error_message = "overlay_address は 10.250.0.11/24 のような CIDR 形式で指定する。"
  }
}

variable "peers" {
  description = "初期接続先の公開 Peer の URI(例: tcp://203.0.113.10:11010)。特定の 1 台だけに依存しないよう、公開ノードを 2 台以上登録する。公開ノード自身は空でもよい"
  type        = list(string)
  default     = []
}

variable "listeners" {
  description = "待ち受けるリスナー。NAT 配下のノードでも、Direct P2P の確立のために既定で待ち受ける"
  type        = list(string)
  default     = ["tcp://0.0.0.0:11010", "udp://0.0.0.0:11010"]
}

variable "ufw_allow" {
  description = "ufw で受信を許可するポート(例: [\"11010/tcp\", \"11010/udp\"])。公開ノードでは、listeners に合わせて許可する(既定拒否の ufw だと、Peer が接続できない)。空なら ufw には触れない。ufw が入っていないホストでは無視する"
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for r in var.ufw_allow : can(regex("^[0-9]+/(tcp|udp)$", r))])
    error_message = "ufw_allow は 11010/tcp のような形式で指定する。"
  }
}

variable "overlay_firewall" {
  description = "true のとき、ufw で、Overlay(overlay_address のネットワーク)からの受信を、overlay_allow だけに絞る(設計書 §7: Overlay に参加できることを、ホストの全ポートへのアクセスと同義にしない)。送信元アドレスで絞るため、EasyTier の設定(インターフェース名)は変えない。ICMP は ufw の before.rules で許可されるので、ping は通る。ufw が入っていないホストでは無視する"
  type        = bool
  default     = false
}

variable "overlay_allow" {
  description = "overlay_firewall が true のとき、Overlay からの受信を許可するポート(例: [\"22/tcp\"])。空なら、Overlay からは何も受けない(ICMP を除く)。一度足したルールは、このリストから外しても自動では消えない(ufw delete が要る)"
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for r in var.overlay_allow : can(regex("^[0-9]+/(tcp|udp)$", r))])
    error_message = "overlay_allow は 22/tcp のような形式で指定する。"
  }
}
