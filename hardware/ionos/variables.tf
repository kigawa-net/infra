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
  description = "ionosがBGPでinuyama(k8s4)へ広告するprefix。WireGuardピア(k8s1/k8s2/soichiro等)のトンネルサブネットへの復路を確保するため172.31.254.0/24を含める"
  type        = list(string)
  default     = ["172.31.254.0/24"]
}

variable "inuyama_ingress_vip" {
  description = "Inuyama ingress VIP for ionos HTTP/HTTPS forwarding. Empty disables those HAProxy frontends."
  type        = string
  default     = "10.0.0.240"
}

variable "minecraft_backend_vip" {
  description = "Inuyama Minecraft backend VIP for ionos TCP/25565 forwarding. Empty disables that HAProxy frontend."
  type        = string
  default     = "10.0.0.241"
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

variable "soichiro_wireguard_address" {
  description = "soichiro の WireGuard IP (AllowedIPs)"
  type        = string
  default     = "172.31.254.13"
}

variable "soichiro_ssh_hostname" {
  description = "soichiro への到達ホスト名 (Cloudflare Tunnel経由)。空の場合はpeer設定なし"
  type        = string
  default     = "ssh.soichiro0520.com"
}

variable "soichiro_ssh_user" {
  type    = string
  default = "kigawa"
}

variable "cf_access_client_id_bitwarden_id" {
  description = "soichiroのCloudflare Access Service Token Client ID (hardware/soichiroと同じ値)。ssh.soichiro0520.comはCloudflare Accessで保護されており、非対話SSH(公開鍵取得)にはService Auth用のポリシーとこのTokenが必要"
  type        = string
  default     = "6a97e2f5-1add-477d-a464-b4cb00102bbf"
}

variable "cf_access_client_secret_bitwarden_id" {
  description = "soichiroのCloudflare Access Service Token Client Secret (hardware/soichiroと同じ値)"
  type        = string
  default     = "944c9557-01db-4c84-988b-b4cb00103314"
}

variable "ci_runner_wireguard_public_key" {
  description = "OneServerMC/infraのGitHub Actions(ubuntu-latest)から一時的にWireGuard接続するためのピア公開鍵。k8s1/k8s2/soichiroと異なりSSHで到達できない(ephemeralなrunner)ため、事前に生成した固定鍵を使う静的ピア設定にしている。秘密鍵はBitwarden(ci-runner-wireguard-private-key)で管理"
  type        = string
  default     = "y9njnYgjixQ/hmu5gXl5/iMFhhOCvhjPn6GMAAgYBmg="
}

variable "ci_runner_wireguard_address" {
  description = "CI runner の WireGuard IP (AllowedIPs)"
  type        = string
  default     = "172.31.254.20"
}

variable "kigawa_infra_ci_runner_wireguard_public_key" {
  description = "kigawa-net/infra自身のGitHub Actions(ubuntu-latest)から一時的にWireGuard接続するためのピア公開鍵。OneServerMC/infraのci_runner_wireguard_*とは別の専用ピア(同じピアを共用すると、両CIが同時実行された場合に接続元IPの奪い合いで不安定になるため)。秘密鍵はBitwarden(kigawa-infra-ci-runner-wireguard-private-key)で管理"
  type        = string
  default     = "4uw9voBKTEC7OSwQkd/RjqyLG+W+/fuwu2xeIUR4GRo="
}

variable "kigawa_infra_ci_runner_wireguard_address" {
  description = "kigawa-net/infra CI runner の WireGuard IP (AllowedIPs)"
  type        = string
  default     = "172.31.254.21"
}

variable "manage_firewall" {
  type    = bool
  default = true
}

variable "firewall_ssh_port" {
  type    = number
  default = 22
}
