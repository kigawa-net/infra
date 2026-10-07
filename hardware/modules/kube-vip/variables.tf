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

variable "health_check_enabled" {
  description = "ローカルの kube-apiserver の /livez を監視し、応答しないときに kube-vip を一時的に止めて VIP を別ノードへ移す (issue #232)。無効にすると、timer を撤去する"
  type        = bool
  default     = true
}

variable "health_peers" {
  description = "他の control-plane の apiserver のアドレス(IP またはホスト名)。止める前に、これらの /livez を確認し、健全なものが 1 つも無ければ止めない(全ノードが一斉に kube-vip を止めて VIP の持ち主がいなくなるのを防ぐ)。空のとき、止めることは決してない"
  type        = list(string)
  default     = []
}

variable "health_interval_seconds" {
  description = "ヘルスチェックの間隔(秒)"
  type        = number
  default     = 10
}

variable "health_fail_threshold" {
  description = "連続して失敗したら kube-vip を止める回数。間隔と合わせて、検知までの時間(間隔 × 回数)になる"
  type        = number
  default     = 3
}

variable "health_ok_threshold" {
  description = "止めた後、連続して成功したら kube-vip を戻す回数(フラッピングを避けるため、失敗の閾値より大きくする)"
  type        = number
  default     = 6
}
