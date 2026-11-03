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

variable "peers" {
  description = "GRE トンネルの相手。name は gre-overlay-tunnel の tunnels の name(インターフェースは gre-<name>)。overlay_address は相手の Overlay のアドレス(10.250.0.x。tun0 から来る gre の送信元)。tunnel_address は、トンネルの内側の、相手のアドレス(トンネル上の 179/tcp の送信元。CIDR なし)"
  type = list(object({
    name            = string
    overlay_address = string
    tunnel_address  = string
  }))
  default = []

  validation {
    condition     = alltrue([for p in var.peers : can(regex("^[a-z0-9-]{1,11}$", p.name))])
    error_message = "name は、小文字・数字・ハイフンの 1〜11 文字にする(インターフェース名は gre-<name> で、15 文字以内)。"
  }

  validation {
    condition     = length(distinct([for p in var.peers : p.name])) == length(var.peers)
    error_message = "name が重複している。"
  }

  validation {
    condition     = alltrue([for p in var.peers : can(cidrhost("${p.overlay_address}/32", 0)) && can(cidrhost("${p.tunnel_address}/32", 0))])
    error_message = "overlay_address と tunnel_address は、IPv4 のアドレス(CIDR なし)にする。"
  }
}
