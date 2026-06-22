variable "host" {
  type    = string
  default = "10.0.1.103"
}

variable "ssh_user" {
  type    = string
  default = "kigawa"
}

variable "k8s_endpoint" {
  type    = string
  default = "k8s.kigawa.net"
}

variable "k8s_version" {
  description = "Kubernetes minor version (e.g. 1.29)"
  type        = string
  default     = "1.29"
}

variable "pod_network_cidr" {
  description = "Pod network CIDR passed to kubeadm init (Flannel default: 10.244.0.0/16)"
  type        = string
  default     = "10.244.0.0/16"
}

variable "cni_manifest_url" {
  description = "CNI manifest URL applied after kubeadm init"
  type        = string
  default     = "https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml"
}

variable "control_plane_host" {
  description = "既存control-planeのSSHホスト。空の場合はkubeadm initを実行し、設定されている場合はclusterが存在すればjoinする"
  type        = string
  default     = "k8s4"
}

variable "control_plane_ssh_user" {
  type    = string
  default = "kigawa"
}

variable "remove_dead_control_plane_ips" {
  description = "etcdから削除する死んだcontrol-planeのIPリスト (スペース区切り)"
  type        = string
  default     = ""
}

variable "ssh_key_bitwarden_id" {
  type    = string
  default = "0393671f-6ef0-4650-be98-b364013f8644"
}

variable "sudo_password_bitwarden_id" {
  type    = string
  default = "52b44d60-7cab-429f-929a-b4340139b6d8"
}

variable "bgp_local_as" {
  description = "Inuyama K8s (ローカル) の AS 番号"
  type        = number
  default     = 65000
}

variable "bgp_peers" {
  description = "iBGPピアのIPリスト"
  type        = list(string)
  default     = ["10.0.1.20", "10.0.1.120"]
}

variable "kube_vip_address" {
  description = "コントロールプレーンVIPのIPアドレス"
  type        = string
  default     = "10.0.1.100"
}

variable "kube_vip_interface" {
  type    = string
  default = "ens18"
}

variable "kube_vip_api_server_ip" {
  description = "kube-vipがリーダー選出で参照するAPIサーバーIP"
  type        = string
  default     = "10.0.1.104"
}

variable "dns_vip" {
  description = "DNS VIPのIPアドレス (全control-planeノードからBGP広告)"
  type        = string
  default     = "10.0.0.53"
}

variable "gateway_vip" {
  description = "デフォルトゲートウェイの仮想IPアドレス"
  type        = string
  default     = "10.0.0.254"
}
