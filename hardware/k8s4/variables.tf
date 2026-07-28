variable "host" {
  type    = string
  default = "192.168.1.120"
}

variable "server_ip" {
  type    = string
  default = "10.0.0.140"
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
  description = "Kubernetes minor version (e.g. 1.32)"
  type        = string
  default     = "1.29"
}

variable "control_plane_host" {
  type    = string
  default = "k8s1"
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
  default     = ["10.0.0.103", "10.0.0.120"]
}

variable "kube_vip_address" {
  description = "コントロールプレーンVIPのIPアドレス"
  type        = string
  default     = "10.0.0.100"
}

variable "kube_vip_interface" {
  type    = string
  default = "ens18"
}

variable "kube_vip_api_server_ip" {
  description = "kube-vipがリーダー選出で参照するAPIサーバーIP"
  type        = string
  default     = "10.0.0.100"
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

variable "inuyama_wireguard_private_key_bitwarden_id" {
  type    = string
  default = "549fe18f-afa9-477e-b4ce-b45f0033e8f2"
}

variable "inuyama_wireguard_public_key_bitwarden_id" {
  type    = string
  default = "b389e2ea-5b86-4bbf-b795-b45f00340001"
}

variable "inuyama_wireguard_interface" {
  type    = string
  default = "wg0"
}

variable "inuyama_wireguard_address" {
  type    = string
  default = "172.31.255.1/30"
}

variable "alice_wireguard_address" {
  type    = string
  default = "172.31.255.2"
}

variable "alice_wireguard_public_key" {
  type    = string
  default = "/bsBpHC0xLxdncldAE1Qo7bWTIXgcJm3Vui6sZOtPhs="
}

variable "alice_wireguard_endpoint" {
  type    = string
  default = "161.248.62.66:51820"
}

variable "ionos_wireguard_interface" {
  type    = string
  default = "wg1"
}

variable "ionos_wireguard_address" {
  type    = string
  default = "172.31.254.1/30"
}

variable "ionos_wireguard_public_key" {
  type    = string
  default = "OH5QiXaMfpmH8nHVU1Onnfom4BZcq4zx5Ux6R6R4LR0="
}

variable "ionos_wireguard_endpoint" {
  type    = string
  default = "74.208.55.86:51820"
}

variable "ionos_bgp_as" {
  type    = number
  default = 65030
}

variable "wireguard_listen_port" {
  type    = number
  default = 51820
}

variable "wireguard_mtu" {
  type    = number
  default = 1420
}

variable "inuyama_asn" {
  type    = number
  default = 65010
}

variable "alice_bgp_as" {
  type    = number
  default = 65020
}

variable "alice_metallb_namespace" {
  type    = string
  default = "metallb-system"
}

variable "alice_metallb_pool_name" {
  type    = string
  default = "main-pool"
}

variable "alice_metallb_base_range" {
  type    = string
  default = "10.0.0.50-10.0.0.99"
}

variable "alice_metallb_reserved_range" {
  type    = string
  default = "10.0.0.240-10.0.0.249"
}

variable "alice_ingress_vip" {
  type    = string
  default = "10.0.0.240"
}

variable "alice_minecraft_vip" {
  type    = string
  default = "10.0.0.241"
}
