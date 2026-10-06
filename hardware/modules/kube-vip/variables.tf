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
  description = "BGPピア(FRR)のAS番号。FRR は同一ホストの kube-vip の BGP を受けられない(bgp-frr の README 参照)ため、実際にはセッションは張れない。bgp_peeraddress は、ピア 0 件だと kube-vip が落ちるので残している"
  type        = number
  default     = 65000
}

variable "api_server_ip" {
  description = "kube-vipがリーダー選出で参照するAPIサーバーIP。VIP自身を指定するとVIP喪失時に自己参照で復旧不能になるため、HAProxyまたは正常なcontrol-planeを指定する"
  type        = string
}

variable "enabled" {
  description = "falseにするとこのノードのkube-vip static podを撤去し、リーダー選出/BGP VIP広報から除外する (ローカル障害時の一時的な緩和策用)"
  type        = bool
  default     = true
}
