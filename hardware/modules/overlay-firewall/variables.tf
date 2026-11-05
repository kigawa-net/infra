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

variable "overlay_cidr" {
  description = "遮断する Overlay のネットワーク(例: 10.250.0.0/24)。Overlay からの受信を、overlay_allow だけに絞る"
  type        = string

  validation {
    condition     = can(cidrhost(var.overlay_cidr, 0))
    error_message = "overlay_cidr は 10.250.0.0/24 のような CIDR 形式で指定する。"
  }
}

variable "overlay_allow" {
  description = "Overlay からの受信を許可するポート(例: [\"22/tcp\"])。ポートを持たないプロトコルは \"gre\" のように書く(GRE トンネル用、設計書 §6.2)。空なら、Overlay からは何も受けない(ICMP を除く)"
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for r in var.overlay_allow : can(regex("^[0-9]+/(tcp|udp)$", r)) || r == "gre"])
    error_message = "overlay_allow は 22/tcp のような形式、または gre で指定する。"
  }
}

variable "snat_source_cidr" {
  description = "空でなければ、この送信元(例: 192.168.1.0/24。LAN の Pod・node)から snat_iface へ出る通信を MASQUERADE する。Overlay 外の送信元の応答を、bao 側の EasyTier が捨てるのを避けるため(送信元をルーターの Overlay の IP にする)。空なら何もしない"
  type        = string
  default     = ""

  validation {
    condition     = var.snat_source_cidr == "" || can(cidrhost(var.snat_source_cidr, 0))
    error_message = "snat_source_cidr は 192.168.1.0/24 のような CIDR 形式、または空にする。"
  }
}

variable "snat_iface" {
  description = "snat_source_cidr の通信を MASQUERADE する出力インターフェース(EasyTier の tun)"
  type        = string
  default     = "tun0"
}

variable "exempt_ifaces" {
  description = "Overlay の送信元でも、このインターフェース(iptables の -i の書式。例: gre-bao+)から入ったパケットは、遮断チェーン(EASYTIER-OVERLAY)を素通りさせる。GRE の中を通る bao → LAN(10.0.0.x)の通信が、送信元 10.250.0.x のせいで DROP されるのを避ける(#463)。空なら何もしない"
  type        = list(string)
  default     = []
}
