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
  description = "Overlay からの受信を許可するポート(例: [\"22/tcp\"])。空なら、Overlay からは何も受けない(ICMP を除く)"
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for r in var.overlay_allow : can(regex("^[0-9]+/(tcp|udp)$", r))])
    error_message = "overlay_allow は 22/tcp のような形式で指定する。"
  }
}
