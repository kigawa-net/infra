variable "host" {
  type    = string
  default = "74.208.55.86"
}

variable "ssh_user" {
  type    = string
  default = "root"
}

variable "ssh_key_bitwarden_id" {
  description = "ionos ホスト自身への接続に使うSSH秘密鍵 (alice/k8s1/k8s2とは別鍵)"
  type        = string
  default     = "1ebd34bf-bfb2-445b-b826-b48f006eba0c"
}

variable "k8s_ssh_key_bitwarden_id" {
  description = "k8s1/k8s2へSSHして公開鍵を取得する際に使うSSH秘密鍵 (alice/k8s1/k8s2共用鍵)"
  type        = string
  default     = "0393671f-6ef0-4650-be98-b364013f8644"
}

variable "sudo_password_bitwarden_id" {
  type    = string
  default = "070a1a26-0753-459e-9efd-b48e0079129f"
}

variable "inuyama_wireguard_private_key_bitwarden_id" {
  description = "Bitwarden ID for the inuyama WireGuard private key. The ionos module records the ID but does not read this secret."
  type        = string
  default     = "549fe18f-afa9-477e-b4ce-b45f0033e8f2"
}

variable "inuyama_wireguard_public_key_bitwarden_id" {
  type    = string
  default = "b389e2ea-5b86-4bbf-b795-b45f00340001"
}

variable "hostname" {
  type    = string
  default = "ionos-01"
}

variable "wireguard_interface" {
  type    = string
  default = "wg0"
}

variable "wireguard_listen_port" {
  type    = number
  default = 51820
}

variable "wireguard_address" {
  type    = string
  default = "172.31.254.2/24"
}

variable "wireguard_mtu" {
  type    = number
  default = 1420
}

variable "wireguard_peer_allowed_ips" {
  type = list(string)
  default = [
    "172.31.254.1/32",
    "10.0.0.0/24",
  ]
}

variable "wireguard_persistent_keepalive" {
  type    = number
  default = 25
}

variable "inuyama_wireguard_address" {
  type    = string
  default = "172.31.254.1"
}

variable "inuyama_wireguard_endpoint" {
  description = "Optional public endpoint for the inuyama WireGuard peer. Ionos can omit this when inuyama dials ionos."
  type        = string
  default     = ""
}

variable "ionos_asn" {
  type    = number
  default = 65030
}

variable "inuyama_asn" {
  type    = number
  default = 65010
}

variable "bgp_router_id" {
  type    = string
  default = "172.31.254.2"
}

variable "inuyama_accepted_prefixes" {
  type = list(string)
  default = [
    "10.0.0.0/24",
  ]
}

variable "ionos_advertised_prefixes" {
  type    = list(string)
  default = []
}

variable "inuyama_ingress_vip" {
  description = "Inuyama ingress VIP for ionos HTTP/HTTPS forwarding. Empty disables those HAProxy frontends."
  type        = string
  default     = "192.168.1.240"
}

variable "minecraft_backend_vip" {
  description = "Inuyama Minecraft backend VIP for ionos TCP/25565 forwarding. Empty disables that HAProxy frontend."
  type        = string
  default     = "192.168.1.241"
}

variable "k8s1_wireguard_address" {
  description = "k8s1 の WireGuard IP (AllowedIPs)"
  type        = string
  default     = "172.31.254.11"
}

variable "k8s1_wireguard_ssh_host" {
  description = "k8s1 の SSH ホスト (空の場合はピア設定なし)"
  type        = string
  default     = "192.168.1.103"
}

variable "k8s1_wireguard_ssh_user" {
  description = "k8s1 への SSH ユーザー"
  type        = string
  default     = "kigawa"
}

variable "k8s2_wireguard_address" {
  description = "k8s2 の WireGuard IP (AllowedIPs)"
  type        = string
  default     = "172.31.254.12"
}

variable "k8s2_wireguard_ssh_host" {
  description = "k8s2 の SSH ホスト (空の場合はピア設定なし)"
  type        = string
  default     = "192.168.1.20"
}

variable "k8s2_wireguard_ssh_user" {
  description = "k8s2 への SSH ユーザー"
  type        = string
  default     = "kigawa"
}

variable "manage_firewall" {
  type    = bool
  default = true
}

variable "firewall_ssh_port" {
  type    = number
  default = 22
}
