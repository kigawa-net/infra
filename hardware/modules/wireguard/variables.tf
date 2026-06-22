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

variable "wireguard_address" {
  description = "WireGuard インターフェースのアドレス (例: 172.31.255.11/24)"
  type        = string
}

variable "wireguard_interface" {
  type    = string
  default = "wg0"
}

variable "server_public_key" {
  description = "接続先 (Alice) の WireGuard 公開鍵"
  type        = string
}

variable "server_endpoint" {
  description = "接続先の WireGuard エンドポイント (IP:port)"
  type        = string
  default     = "161.248.62.66:51820"
}

variable "server_allowed_ips" {
  description = "WireGuard トンネル経由でルーティングするIPレンジ"
  type        = list(string)
  default     = ["172.31.255.0/24"]
}

variable "persistent_keepalive" {
  type    = number
  default = 25
}
