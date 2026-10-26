variable "host" {
  description = "k8s-worker1 の自宅 LAN のアドレス。CI(GitHub-hosted runner)から、WireGuard(ionos → k8s4 の ci-ssh-forward)経由で SSH する"
  type        = string
  default     = "192.168.1.228"
}

variable "ssh_user" {
  type    = string
  default = "kigawa"
}

variable "control_plane_ssh_key_bitwarden_id" {
  type    = string
  default = "0393671f-6ef0-4650-be98-b364013f8644"
}

variable "sudo_password_bitwarden_id" {
  type    = string
  default = "52b44d60-7cab-429f-929a-b4340139b6d8"
}

variable "lan_interface" {
  description = "自宅 LAN(192.168.1.0/24)側のインターフェース名(netplan で設定する)"
  type        = string
  default     = "ens18"
}

variable "lan_gateway" {
  description = "自宅 LAN のデフォルトゲートウェイ(物理ルーター)。prefix なし"
  type        = string
  default     = "192.168.1.1"
}

variable "core_router_vip" {
  description = "Core Router VIP (#241)。k8s1 / k8s2 / k8s4 の keepalived(VRRP)が持つ、LAN(192.168.1.0/24)側の仮想コアルーターの next-hop。prefix なし"
  type        = string
  default     = "192.168.1.200"
}
