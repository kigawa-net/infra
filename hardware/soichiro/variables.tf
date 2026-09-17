variable "host" {
  description = "soichiro への直接SSH到達アドレス (パブリックIPまたは現在のLAN上のIP。WireGuardトンネルではなく、Terraformプロビジョニング用のSSH接続先)"
  type    = string
  default = "" # TODO: soichiroの実機セットアップ後、実際に疎通するアドレスを設定する
}

variable "ssh_user" {
  type    = string
  default = "kigawa"
}

variable "ssh_private_key_bitwarden_id" {
  description = "soichiro への SSH 秘密鍵の Bitwarden Secret ID (事前に bws でsoichiro用の鍵を登録しておくこと)"
  type    = string
  default = "" # TODO: Bitwardenにsoichiro用SSH鍵を登録し、そのSecret IDを設定する
}

variable "sudo_password_bitwarden_id" {
  type    = string
  default = "52b44d60-7cab-429f-929a-b4340139b6d8"
}

variable "k8s_endpoint" {
  description = "Kubernetes control-plane API endpoint (VIP)"
  type    = string
  default = "10.0.0.100"
}

variable "k8s_version" {
  description = "Kubernetes minor version (e.g. 1.29)"
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

variable "control_plane_ssh_key_bitwarden_id" {
  type    = string
  default = "0393671f-6ef0-4650-be98-b364013f8644"
}

variable "wireguard_address" {
  description = "soichiro 側 WireGuard インターフェースのアドレス (alice の soichiro_wireguard_address と対になる /24 CIDR表記)"
  type        = string
  default     = "172.31.255.13/24"
}

variable "wireguard_server_public_key" {
  description = "Alice の WireGuard 公開鍵 (cat /etc/wireguard/alice_public.key で取得)"
  type        = string
  default     = "/bsBpHC0xLxdncldAE1Qo7bWTIXgcJm3Vui6sZOtPhs="
}

variable "wireguard_server_endpoint" {
  description = "Alice の WireGuard エンドポイント"
  type        = string
  default     = "161.248.62.66:51820"
}

variable "wireguard_server_allowed_ips" {
  description = "WireGuardトンネル経由でルーティングするIPレンジ。クラスタLAN(10.0.0.0/24)へのBGPルート伝播が別途構成されるまでは、暫定的にトンネルサブネットのみを指定している点に注意 (setup doc参照)"
  type        = list(string)
  default     = ["172.31.255.0/24"]
}
