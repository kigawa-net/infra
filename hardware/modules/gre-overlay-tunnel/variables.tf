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

variable "tunnels" {
  description = "作る GRE トンネル。name はインターフェース名の gre- より後ろ(例: k8s4 → gre-k8s4。Linux の名前の上限 15 文字のため、11 文字まで)。local / remote は、両端の EasyTier の Overlay のアドレス(10.250.0.x)。address は、トンネルの内側のアドレスと長さ(/31 を 1 本ずつ。設計書 §3 の 172.31.250.0/24)。mtu は、Overlay の tun0(1360)から GRE の 24 バイトを引いた値以下(既定 1300)"
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
    condition     = alltrue([for t in var.tunnels : can(cidrhost(t.address, 0)) && can(regex("^[0-9.]+/(30|31)$", t.address))])
    error_message = "address は 172.31.250.0/31 のような、/30 か /31 のアドレスにする。"
  }

  validation {
    condition     = alltrue([for t in var.tunnels : t.mtu >= 576 && t.mtu <= 1336 && t.mtu == floor(t.mtu)])
    error_message = "mtu は、576〜1336 の整数にする(Overlay の tun0 の MTU 1360 から、GRE の 24 バイトを引いた値以下)。"
  }
}
