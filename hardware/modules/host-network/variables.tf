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
  description = "netplan で設定する LAN 側のインターフェース名 (例: ens18)"
  type        = string
}

variable "address_cidr" {
  description = "ノードの LAN アドレス (例: 192.168.1.228/24)。k8s が持つノードの IP と、CI が SSH する先に合わせる"
  type        = string
}

variable "gateway" {
  description = "デフォルトゲートウェイ (例: 192.168.1.1)。prefix なし"
  type        = string
}
