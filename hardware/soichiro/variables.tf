variable "ssh_hostname" {
  description = "soichiro への到達ホスト名。Cloudflare Tunnel (cloudflared access ssh) 経由でのみ到達可能なため、通常のIPアドレスではなくこのホスト名を使う"
  type        = string
  default     = "ssh.soichiro0520.com"
}

variable "ssh_user" {
  type    = string
  default = "kigawa"
}

variable "ssh_private_key_path" {
  description = "soichiro への SSH 秘密鍵のローカルファイルパス (soichiroはBitwardenを使わず、ローカルの鍵ファイルを直接読み込む)"
  type        = string
  default     = "" # TODO: 例 "~/.ssh/soichiro" のように、soichiro用秘密鍵のパスを設定する
}

variable "sudo_password" {
  description = "soichiro の sudo パスワード (soichiroはBitwardenを使わず、変数で直接渡す。TF_VAR_sudo_password環境変数または非コミットのtfvarsで指定すること)"
  type        = string
  sensitive   = true
  default     = "" # TODO: soichiro自身のsudoパスワードを設定する(コミットしないこと)
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
  description = "既存クラスタのcontrol-plane(k8s1)へのSSH鍵。こちらはsoichiro自身の資格情報ではなく、joinトークンを発行するための既存クラスタ側の資格情報のため、引き続きBitwardenを使用する"
  type        = string
  default     = "0393671f-6ef0-4650-be98-b364013f8644"
}

variable "control_plane_sudo_password_bitwarden_id" {
  description = "既存クラスタのcontrol-plane(k8s1)のsudoパスワード。soichiro自身の資格情報ではなく、joinトークン発行のためのcontrol-plane側の資格情報のため、引き続きBitwardenを使用する"
  type        = string
  default     = "52b44d60-7cab-429f-929a-b4340139b6d8"
}

variable "k8s_endpoint" {
  description = "Kubernetes control-plane API endpoint (VIP)"
  type        = string
  default     = "10.0.0.100"
}

variable "k8s_version" {
  description = "Kubernetes minor version (e.g. 1.29)"
  type        = string
  default     = "1.29"
}

variable "wireguard_address" {
  description = "soichiro 側 WireGuard インターフェースのアドレス (ionos の soichiro_wireguard_address と対になる /24 CIDR表記)"
  type        = string
  default     = "172.31.254.13/24"
}

variable "wireguard_server_public_key" {
  description = "ionos の WireGuard 公開鍵。aliceは廃止されたため、hardware/ionosを恒久的なゲートウェイとして使う(hardware/k8s1等の wireguard_ionos_server_public_key と同一値)"
  type        = string
  default     = "OH5QiXaMfpmH8nHVU1Onnfom4BZcq4zx5Ux6R6R4LR0="
}

variable "wireguard_server_endpoint" {
  description = "ionos の WireGuard エンドポイント"
  type        = string
  default     = "74.208.55.86:51820"
}

variable "wireguard_server_allowed_ips" {
  description = "WireGuardトンネル経由でルーティングするIPレンジ。BGP(hardware/ionos の ionos_advertised_prefixes と hardware/k8s4 の import_prefixes)でクラスタ側への復路を確保している"
  type        = list(string)
  default     = ["172.31.254.0/24"]
}

variable "node_exporter_version" {
  description = "node_exporter のバージョン (例: 1.7.0)。hardware/modules/node-exporter と同じデフォルトに揃えている"
  type        = string
  default     = "1.7.0"
}
