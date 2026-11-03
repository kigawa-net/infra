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

variable "overlay_address" {
  description = "このノードの Overlay の IP(CIDR なし。例: bao-02 は 10.250.0.1、k8s4 は 10.250.0.11)。トンネルの local と、ufw の許可の送信元の基準になる"
  type        = string

  validation {
    condition     = can(cidrhost("${var.overlay_address}/32", 0))
    error_message = "overlay_address は 10.250.0.1 のような IPv4 のアドレスだけで指定する(CIDR なし)。"
  }
}

variable "peers" {
  description = <<-EOT
    トンネルの相手。1 件につき 1 本の GRE トンネル(インターフェース名は gre-<name>)を張る。
    - name: 小文字英数字 1〜11 文字(gre- を足して 15 文字以内)。同じノードの中で重複させない
    - overlay_address: 相手の Overlay の IP(CIDR なし)。GRE の remote になる
    - local_tunnel_cidr: 自分側のトンネルのアドレス(/31。例: 172.31.250.0/31)。gre-<name> に付ける
    - peer_tunnel_address: 相手側のトンネルのアドレス(local_tunnel_cidr と同じ /31 の、もう一方。例: 172.31.250.1)。BGP の neighbor になる
    設計: docs/frr-gre-overlay-design.md §3
  EOT
  type = list(object({
    name                = string
    overlay_address     = string
    local_tunnel_cidr   = string
    peer_tunnel_address = string
  }))

  validation {
    condition     = length(var.peers) > 0
    error_message = "peers は 1 件以上にする。"
  }

  validation {
    condition     = alltrue([for p in var.peers : can(regex("^[a-z0-9]{1,11}$", p.name))])
    error_message = "peers の name は小文字英数字 1〜11 文字にする(インターフェース名 gre-<name> が 15 文字以内に収まるように)。"
  }

  validation {
    condition     = length(distinct([for p in var.peers : p.name])) == length(var.peers)
    error_message = "peers の name は重複させない。"
  }

  validation {
    condition     = alltrue([for p in var.peers : can(cidrhost("${p.overlay_address}/32", 0))])
    error_message = "peers の overlay_address は 10.250.0.11 のような IPv4 のアドレスだけで指定する(CIDR なし)。"
  }

  validation {
    condition     = alltrue([for p in var.peers : can(regex("/31$", p.local_tunnel_cidr)) && can(cidrhost(p.local_tunnel_cidr, 0))])
    error_message = "peers の local_tunnel_cidr は 172.31.250.0/31 のような /31 の CIDR にする。"
  }

  validation {
    condition = alltrue([
      for p in var.peers :
      can(cidrhost("${p.peer_tunnel_address}/32", 0))
      && contains([cidrhost(p.local_tunnel_cidr, 0), cidrhost(p.local_tunnel_cidr, 1)], p.peer_tunnel_address)
      && p.peer_tunnel_address != split("/", p.local_tunnel_cidr)[0]
    ])
    error_message = "peers の peer_tunnel_address は、local_tunnel_cidr と同じ /31 の、もう一方の IP にする(自分と同じ IP は不可)。"
  }
}

variable "mtu" {
  description = "トンネルの MTU。既定 1300(tun0 の MTU 1360 から、GRE の 24 バイトを引いた余裕を見た値。設計書 §8)。576〜1336"
  type        = number
  default     = 1300

  validation {
    condition     = var.mtu >= 576 && var.mtu <= 1336
    error_message = "mtu は 576〜1336 の範囲にする(tun0 の MTU から GRE の 24 バイトを引いた値以下)。"
  }
}

variable "clamp_mss" {
  description = "true のとき、gre+ へ出る TCP の SYN の MSS を PMTU に合わせて絞る(iptables の mangle FORWARD、TCPMSS)。control-plane 側(LAN の Pod から、トンネルを通って bao へ出る通信)で使う(設計書 §6.1)。停止時に外す"
  type        = bool
  default     = false
}

variable "firewall" {
  description = "none のとき、ファイアウォールには触れない。ufw のとき、tun0 から相手の Overlay の gre(プロトコル 47)を先頭に入れて許可し、gre-<name> から相手のトンネルの 179/tcp を許可する(bao 側。設計書 §6.2)。ufw の規則は、外しても自動では消えない(ufw delete が要る)"
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "ufw"], var.firewall)
    error_message = "firewall は none か ufw にする。"
  }
}
