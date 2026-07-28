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

variable "interface" {
  description = "netplanで設定する物理インターフェース名 (例: ens18)"
  type        = string
}

variable "primary_cidr" {
  description = "既存LAN側のアドレス (例: 192.168.1.120/24)。SSH到達性を維持するため変更しない"
  type        = string
}

variable "primary_gateway" {
  description = "既存LAN側のデフォルトゲートウェイ"
  type        = string
}

variable "secondary_cidr" {
  description = "10.0.0.0/24側の追加アドレス (server_ip変数から /24 で構成する)"
  type        = string
}

variable "nameservers" {
  type    = list(string)
  default = []
}
