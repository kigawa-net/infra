variable "host" {
  description = "SSH の接続先。DHCP に依存しないよう、対象の NIC の、すでに付いている別のアドレスで接続してもよい"
  type        = string
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

variable "interface" {
  description = "固定のアドレスとデフォルト経路を足す NIC(例: ens18)"
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+$", var.interface))
    error_message = "interface は、英数字と _ . - だけにしてください。"
  }
}

variable "address" {
  description = "足す IPv4 アドレス(CIDR。例: 192.168.1.228/24)。既存のアドレスは、そのまま残す"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}/[0-9]{1,2}$", var.address))
    error_message = "address は IPv4 の CIDR(例: 192.168.1.228/24)にしてください。"
  }
}

variable "gateway" {
  description = "デフォルト経路のゲートウェイ(IPv4。例: 192.168.1.1)"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", var.gateway))
    error_message = "gateway は IPv4 アドレスにしてください。"
  }
}
