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

variable "bird_image" {
  type    = string
  default = "kathara/bird2:latest"
}

variable "bgp_router_id" {
  description = "BIRDのrouter ID (通常はノードのIP)"
  type        = string
}

variable "bgp_local_as" {
  description = "ローカルAS番号"
  type        = number
  default     = 65000
}

variable "bgp_peers" {
  description = "iBGPピアのIPリスト (全て同じAS番号を使用)"
  type        = list(string)
  default     = []
}

variable "kube_vip_as" {
  description = "kube-vipのAS番号 (BIRD2と区別するため別ASを使用)"
  type        = number
  default     = 65001
}

variable "advertised_vips" {
  description = "BGP経由で広告するVIPのIPリスト (各ノードのloopbackに追加してstaticルートで広告)"
  type        = list(string)
  default     = []
}
