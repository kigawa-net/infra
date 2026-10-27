variable "enabled" {
  description = "false のときは、何も作らず、Bitwarden にも触れない。WireGuard と journald-limit は適用済み(2026-10-27)なので true。OpenBao は openbao_node_enabled で別に制御する"
  type        = bool
  default     = true
}

variable "openbao_node_enabled" {
  description = "true のときだけ OpenBao を入れる(enabled = true も必要)。false なら WireGuard と journald-limit だけを適用する。TLS 証明書・peers・openbao_deb_sha256 が揃ってから true にする"
  type        = bool
  default     = false
}

variable "host" {
  description = "bao-02 の SSH の接続先(別 VPS のグローバルアドレス)"
  type        = string
  default     = "207.231.111.196"
}

variable "ssh_user" {
  type    = string
  default = "root"
}

variable "ssh_key_bitwarden_id" {
  description = "bao-02 専用の SSH 秘密鍵の bws の ID(bao-02-ssh-private-key)"
  type        = string
  default     = "826652fb-c615-4fe1-88c3-b4f000bf1f37"
}

variable "sudo_password_bitwarden_id" {
  description = "bao-02 の sudo パスワードの bws の ID(bao-02-sudo-password)"
  type        = string
  default     = "57ba07a6-2ac8-4022-b8ea-b4ef011b362e"
}

variable "tls_cert_bitwarden_id" {
  description = "サーバ証明書(PEM)の bws の ID。外部の CA で発行したもの。未設定のままにしている"
  type        = string
  default     = ""
}

variable "tls_key_bitwarden_id" {
  description = "サーバ秘密鍵(PEM)の bws の ID。未設定のままにしている"
  type        = string
  default     = ""
}

variable "tls_ca_bitwarden_id" {
  description = "発行元の CA 証明書(PEM)の bws の ID。未設定のままにしている"
  type        = string
  default     = ""
}

variable "node_id" {
  description = "raft の node_id"
  type        = string
  default     = "bao-02"
}

variable "wg_address" {
  description = "bao-02 の WireGuard 上の IPv4 アドレス(単独、CIDR なし)。hardware/ionos の bao02_wireguard_address と一致させる。/32 で wg0 に載せる"
  type        = string
  default     = "172.31.254.30"
}

variable "wireguard_server_public_key" {
  description = "IONOS hub(hardware/ionos)の WireGuard 公開鍵。cat /etc/wireguard/ionos_public.key で取得した値(公開情報)。空文字のままでは enabled = true にできない"
  type        = string
  default     = "OH5QiXaMfpmH8nHVU1Onnfom4BZcq4zx5Ux6R6R4LR0="
}

variable "wireguard_server_endpoint" {
  description = "IONOS hub の WireGuard エンドポイント(IP:port)。bao-02 から hub へ発信する(hub 側に endpoint は持たせない)"
  type        = string
  default     = "74.208.55.86:51820"
}

variable "wireguard_server_allowed_ips" {
  description = "hub 経由でルーティングする IP レンジ。raft の相手(他のスポーク)は 172.31.254.0/24、bao-01(K8s 上の StatefulSet)の LoadBalancer VIP は Inuyama の 10.0.0.0/24 にあるため、両方を hub に向ける。bao-02 は BGP を話さないので、静的に指定する。hub 側の bao-02 ピアは /32 だけなので、10.0.0.0/24 は k8s4 ピアの AllowedIPs と衝突しない(issue #121)"
  type        = list(string)
  default     = ["172.31.254.0/24", "10.0.0.0/24"]
}

variable "peers" {
  description = "他の bao ノード(retry_join 先)。bao-02 / bao-03 の node_id と WireGuard の IPv4。未設定のままにしている"
  type = list(object({
    node_id = string
    address = string
  }))
  default = []
}

variable "openbao_version" {
  description = "固定する OpenBao のバージョン(X.Y.Z)。latest は使わない。2.7.2 は 2026-10-26 のセキュリティ修正リリース(GHSA 5 件)"
  type        = string
  default     = "2.7.2"
}

variable "openbao_deb_sha256" {
  description = "公式の .deb(openbao_2.7.2_linux_amd64.deb)の SHA256。リリースの checksums.txt と、ダウンロードした実物の sha256sum の両方で一致を確認した(2026-10-27)。openbao_version を上げるときは、必ず更新する"
  type        = string
  default     = "42bd0890a8e2060e5f29410ea828ee047aa2de21028045731a0516d5a532928c"
}

variable "wipe_data_on_failure" {
  description = "true のときだけ、失敗時に /var/lib/openbao を消す(初回構築の失敗からの復旧用)。既定 false"
  type        = bool
  default     = false
}

# EasyTier(kigawa-net/infra#350、docs/network-vpn-architecture-design.md §4.1)。
# false のときは、何も作らず、Bitwarden にも触れない(plan は no-op)。ネットワーク Secret を bws に登録してから true にする。
variable "easytier_enabled" {
  description = "true のときだけ EasyTier を入れる。easytier_network_secret_bitwarden_id が必要"
  type        = bool
  default     = false
}

variable "easytier_network_secret_bitwarden_id" {
  description = "EasyTier のネットワーク Secret の bws の ID。ionos と bao-02 で同じ値を使う。未登録のまま(空)"
  type        = string
  default     = ""
}

variable "easytier_network_name" {
  type    = string
  default = "kigawa-net"
}

variable "easytier_version" {
  description = "採用バージョン(docs/network-vpn-architecture-design.md §4.1)。GitHub の latest(prerelease でない最新)"
  type        = string
  default     = "2.6.4"
}

variable "easytier_sha256" {
  description = "easytier-linux-x86_64-v2.6.4.zip の SHA-256(自分でダウンロードして計算し、GitHub の digest とも一致を確認した値)。easytier_version を上げるときは、必ず更新する"
  type        = string
  default     = "61b659eaedba658fa66fe47d17e1426cdd77e5d02fa15fed447bb4357c09dfd6"
}

variable "easytier_overlay_address" {
  description = "このノードの EasyTier の Overlay アドレス(設計書 §4.1)"
  type        = string
  default     = "10.250.0.1/24"
}

variable "easytier_peers" {
  description = "もう一方の公開ノードへの接続先(初期接続先)"
  type        = list(string)
  default     = ["tcp://74.208.55.86:11010"]
}
