variable "host" {
  type    = string
  default = "192.168.1.150"
}

variable "server_ip" {
  type    = string
  default = "10.0.0.40"
}

variable "ssh_user" {
  type    = string
  default = "kigawa"
}

variable "k8s_endpoint" {
  type    = string
  default = "10.0.0.100"
}

variable "k8s_version" {
  description = "Kubernetes minor version (e.g. 1.30)"
  type        = string
  default     = "1.30"
}

variable "control_plane_host" {
  description = "kubeadm token createを実行するcontrol-planeのアドレス。ホスト名(k8s1)は自己ホストランナーでしか解決できず、ubuntu-latest(WireGuard経由)では空のtokenになるためIPで指定する(k8s1 = 10.0.0.103)"
  type        = string
  default     = "10.0.0.103"
}

variable "control_plane_ssh_user" {
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

variable "core_router_vip" {
  description = "Core Router VIP (#241)。k8s1 / k8s2 / k8s4 の keepalived(VRRP)が持つ、LAN(192.168.1.0/24)側の仮想コアルーターの next-hop。prefix なし"
  type        = string
  default     = "192.168.1.200"
}
