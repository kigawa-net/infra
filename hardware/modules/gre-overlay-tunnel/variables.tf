variable "host" {
  type = string
}

variable "ssh_user" {
  type = string
}

variable "sudo_password" {
  type      = string
  sensitive = true
}

variable "tunnels" {
  description = "作る GRE トンネル。name はインターフェース名の gre- より後ろ(例: k8s4 → gre-k8s4。Linux の名前の上限 15 文字のため、11 文字まで)。local / remote は、両端の EasyTier の Overlay のアドレス(10.250.0.x)。address は、トンネルの内側の、自分のアドレスと長さ(/31 を 1 本ずつ。設計書 §3 の 172.31.250.0/24。相手のアドレスは、/31 のもう片方)。mtu は、Overlay の tun0(1360)から GRE の 24 バイトを引いた値以下(既定 1300)"
  type = list(object({
    name    = string
    local   = string
    remote  = string
    address = string
    mtu     = optional(number, 1300)
  }))
  default = []

  validation {
    condition     = alltrue([for t in var.tunnels : can(regex("^[a-z0-9-]{1,11}$", t.name))])
    error_message = "name は、小文字・数字・ハイフンの 1〜11 文字にする(インターフェース名は gre-<name> で、15 文字以内)。"
  }

  validation {
    condition     = length(distinct([for t in var.tunnels : t.name])) == length(var.tunnels)
    error_message = "name が重複している。"
  }

  validation {
    condition     = alltrue([for t in var.tunnels : can(cidrhost("${t.local}/32", 0)) && can(cidrhost("${t.remote}/32", 0)) && t.local != t.remote])
    error_message = "local と remote は、異なる IPv4 のアドレス(CIDR なし)にする。"
  }

  validation {
    condition     = alltrue([for t in var.tunnels : can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+/31$", t.address)) && can(cidrhost(t.address, 1))])
    error_message = "address は 172.31.250.0/31 のような、/31 の IPv4 アドレスにする(相手のアドレスを、/31 のもう片方から決めるため)。"
  }

  validation {
    condition     = alltrue([for t in var.tunnels : t.mtu >= 576 && t.mtu <= 1336 && t.mtu == floor(t.mtu)])
    error_message = "mtu は、576〜1336 の整数にする(Overlay の tun0 の MTU 1360 から、GRE の 24 バイトを引いた値以下)。"
  }
}

variable "manage_firewall" {
  description = "true のとき、GRE(-i <overlay_iface> -p gre、相手の Overlay から)と、トンネル上の 179/tcp(-i gre-<name>、相手のトンネル内のアドレスから)の許可を、iptables の INPUT の先頭に入れる(ufw・modules/overlay-firewall の DROP より前)。フィルタのないホストでは、false でよい"
  type        = bool
  default     = true
}

variable "overlay_iface" {
  description = "EasyTier の tun のインターフェース名。GRE の許可の入力インターフェースに使う"
  type        = string
  default     = "tun0"

  validation {
    condition     = can(regex("^[a-zA-Z0-9._-]{1,15}$", var.overlay_iface))
    error_message = "overlay_iface は、インターフェース名(15 文字以内)にする。"
  }
}

