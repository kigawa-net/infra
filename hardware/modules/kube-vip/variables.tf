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

variable "vip_address" {
  description = "コントロールプレーンVIPのIPアドレス"
  type        = string
}

variable "interface" {
  description = "VIPを割り当てるネットワークインターフェース名"
  type        = string
  default     = "ens18"
}

variable "kube_vip_image" {
  type    = string
  default = "ghcr.io/kube-vip/kube-vip:v0.8.9"
}

variable "k8s_port" {
  type    = number
  default = 6443
}

variable "kube_vip_bgp_as" {
  description = "kube-vip自身のAS番号"
  type        = number
  default     = 65001
}

variable "bgp_peer_as" {
  description = "BGPピア(BIRD2)のAS番号"
  type        = number
  default     = 65000
}

variable "api_server_ip" {
  description = "kube-vipがリーダー選出で参照するAPIサーバーIP。VIP自身を指定するとVIP喪失時に自己参照で復旧不能になるため、HAProxyまたは正常なcontrol-planeを指定する"
  type        = string
}
