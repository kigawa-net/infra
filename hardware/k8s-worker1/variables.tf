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

variable "static_network_enabled" {
  description = "true にすると、modules/static-network で、固定のアドレスとデフォルト経路を足す(kigawa-net/infra#317)"
  type        = bool
  default     = true
}

variable "static_network_ssh_host" {
  description = "static-network の SSH の接続先。空なら host(192.168.1.228)を使う。192.168.1.228 が消えている間は、192.168.1.105 を指定する"
  type        = string
  default     = ""
}

variable "static_network_interface" {
  description = "固定のアドレスとデフォルト経路を足す NIC"
  type        = string
  default     = "ens18"
}

variable "static_network_address" {
  description = "足す IPv4 アドレス(CIDR)。Kubernetes が、このノードの IP として登録している 192.168.1.228(MAAS の DHCP の予約と同じ)。既存の 192.168.1.105 は、そのまま残る"
  type        = string
  default     = "192.168.1.228/24"
}

variable "static_network_gateway" {
  description = "デフォルト経路のゲートウェイ(自宅ルーター、スイッチ)"
  type        = string
  default     = "192.168.1.1"
}

variable "core_router_vip" {
  description = "Core Router VIP (#241)。k8s1 / k8s2 / k8s4 の keepalived(VRRP)が持つ、LAN(192.168.1.0/24)側の仮想コアルーターの next-hop。prefix なし"
  type        = string
  default     = "192.168.1.200"
}
