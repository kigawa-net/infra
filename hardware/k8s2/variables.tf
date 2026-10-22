variable "host" {
  type    = string
  default = "192.168.1.20"
}

variable "server_ip" {
  type    = string
  default = "10.0.0.120"
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
  description = "Kubernetes minor version (e.g. 1.30)"
  type        = string
  default     = "1.30"
}

variable "control_plane_host" {
  type    = string
  default = "k8s4"
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
  default     = ["10.0.0.103", "10.0.0.140"]
}

variable "kube_vip_address" {
  description = "コントロールプレーンVIPのIPアドレス"
  type        = string
  default     = "10.0.0.100"
}

variable "kube_vip_interface" {
  type    = string
  default = "enp0s31f6"
}

variable "ionos_return_gateway" {
  description = <<-DESC
    LAN(10.0.0.0/24)発で IONOS(172.31.254.2)宛の通信の、next-hop(k8s4 の LAN アドレス)。
    k8s2 は IONOS と専用の wg1(172.31.254.12/32)を持ち、172.31.254.2/32 を wg1 に向けている(eBGP の到達性のため)。
    その結果、LAN 経由で来た要求(IONOS → 10.0.0.120 / VIP)への返信も、送信元 10.0.0.x のまま wg1 で IONOS に返り、
    IONOS の wg0(k8s2 の peer の AllowedIPs は 172.31.254.12/32 のみ)で破棄される。送信元が LAN のときだけ、k8s4 経由で返す。
    IONOS が 10.0.0.0/24 宛に使う peer(k8s4)と同じ経路になるため、往復が揃う。
  DESC
  type        = string
  default     = "10.0.0.140"
}

variable "kube_vip_api_server_ip" {
  description = "kube-vipがリーダー選出で参照するAPIサーバーIP (VIP喪失時の自己参照デッドロックを避けるため、kube_vip_addressとは別の到達可能なアドレスにすること)。127.0.0.1(自ノードのローカルAPIサーバー)を指定し、外部LB(旧: host1のhaproxy VM)への単一障害点依存を避ける"
  type        = string
  default     = "127.0.0.1"
}

variable "kube_vip_health_peers" {
  description = "kube-vip のヘルス連動で、止める前に確認する、他の control-plane の apiserver (k8s1 / k8s4 の server_ip)。健全なものが 1 つも無ければ止めない (issue #232)"
  type        = list(string)
  default     = ["10.0.0.103", "10.0.0.140"]
}

variable "etcd_backup_enabled" {
  description = "etcd の定期スナップショット(R2 へ、age で暗号化)を有効にする (issue #189)。age の公開鍵と R2 の認証情報が揃うまでは false"
  type        = bool
  default     = true
}

variable "etcd_backup_age_recipient" {
  description = "スナップショットを暗号化する age の公開鍵(age1...)。秘密鍵は、ノードに置かず、Bitwarden に保管する(公開鍵は秘密ではない)"
  type        = string
  default     = "age1n5ccnfwjrmd24vruuj4jjlag3lzdglqqv3u8ve3xa0mlqxqhrewsdfwf7a"
}

variable "etcd_backup_r2_access_key_bitwarden_id" {
  description = "etcd-backup バケット限定の R2 アクセスキー ID の Bitwarden Secrets の UUID(etcd-backup-r2-access-key-id)。UUID は秘密ではない。空のときは、Bitwarden に触れない"
  type        = string
  default     = "dcb5a742-001d-4b04-9581-b4dd00263c30"
}

variable "etcd_backup_r2_secret_bitwarden_id" {
  description = "etcd-backup バケット限定の R2 シークレットアクセスキーの Bitwarden Secrets の UUID(etcd-backup-r2-secret-access-key)"
  type        = string
  default     = "c4779430-503a-4cc0-b4fd-b4dd00263d66"
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

variable "core_router_vip" {
  description = "Core Router VIP (#241)。LAN(192.168.1.0/24)側の仮想コアルーターの next-hop。prefix 付き"
  type        = string
  default     = "192.168.1.200/24"
}

variable "wireguard_address" {
  description = "WireGuard インターフェースのアドレス"
  type        = string
  default     = "172.31.255.12/24"
}

variable "wireguard_server_public_key" {
  description = "Alice の WireGuard 公開鍵。aliceは廃止済みのため空にし、module.wireguard(count = ... != \"\" ? 1 : 0)を無効化してトンネル自体を破棄する"
  type        = string
  default     = ""
}

variable "wireguard_server_endpoint" {
  description = "Alice の WireGuard エンドポイント"
  type        = string
  default     = "161.248.62.66:51820"
}

variable "wireguard_server_allowed_ips" {
  description = "WireGuard トンネル経由でルーティングする IP レンジ"
  type        = list(string)
  default     = ["172.31.255.0/24"]
}

variable "wireguard_ionos_interface" {
  description = "Ionos hub 向け WireGuard インターフェース名"
  type        = string
  default     = "wg1"
}

variable "wireguard_ionos_address" {
  description = "Ionos hub 向け WireGuard インターフェースのアドレス。/24ではなく/32にすることで、172.31.254.0/24宛のkernel-connected経路が自動生成されるのを防ぐ(ionos以外の宛先はBGP経由(k8s4/inuyama)で正しくルーティングされるべきだが、/24だとこのkernel経路がBGP経路より優先されてしまい、ionosの暗号ルーティング(AllowedIPs)チェックで送信元不一致により無言破棄されていた)"
  type        = string
  default     = "172.31.254.12/32"
}

variable "wireguard_ionos_server_public_key" {
  description = "Ionos の WireGuard 公開鍵 (cat /etc/wireguard/ionos_public.key で取得)"
  type        = string
  default     = "OH5QiXaMfpmH8nHVU1Onnfom4BZcq4zx5Ux6R6R4LR0="
}

variable "wireguard_ionos_server_endpoint" {
  description = "Ionos の WireGuard エンドポイント"
  type        = string
  default     = "74.208.55.86:51820"
}

variable "wireguard_ionos_server_allowed_ips" {
  description = "WireGuard トンネル経由でルーティングする IP レンジ (Ionos hub)。k8s2はk8s4(inuyama)の冗長化として2本目のeBGPゲートウェイを兼ねるため、ionos自身の/32だけでなく172.31.254.0/24全体を含める(k8s4のionos_wireguard_allowed_ipsと同じ理由: soichiro等の他ピア宛トラフィックをこのトンネル経由で中継できるようにする)"
  type        = list(string)
  default     = ["172.31.254.0/24"]
}

# --- IONOS との専用リンク(kigawa-net/infra#238) ---------------------------------------------------
# wg1(上)は IONOS の wg0 に載っていて、IONOS 側の k8s2 の peer の AllowedIPs は 172.31.254.12/32 だけ。そのため、送信元が 10.0.0.x の
# パケットを IONOS が破棄する。専用のリンク(peer は 1 つ、AllowedIPs = 0.0.0.0/0)なら、この制約がない。
# 鍵は新しく作らない(wg1 と同じ /etc/wireguard/privatekey を使う。IONOS 側の peer の公開鍵も、そのまま使える)。
variable "ionos_link_interface" {
  description = "IONOS との専用リンクのインターフェース名"
  type        = string
  default     = "wg-ionos"
}

variable "ionos_link_address" {
  description = "IONOS との専用リンクの、k8s2 側のアドレス(172.31.252.4/30 の .6)"
  type        = string
  default     = "172.31.252.6/30"
}

variable "ionos_link_peer_address" {
  description = "IONOS との専用リンクの、IONOS 側のアドレス(BGP の neighbor)"
  type        = string
  default     = "172.31.252.5"
}

variable "ionos_link_import_enabled" {
  description = <<-DESC
    k8s2 の IONOS との専用リンク(wg-ionos)の eBGP から、IONOS の経路(172.31.254.0/24 と Soichiro の管理 IP)を取り込むか。
    true: k8s4 の専用リンクが落ちたときの、Inuyama → IONOS の戻りのフォールバックになる(k8s4 は local-preference 200、こちらは 100)。
    false: 何も取り込まない(切り替え前の状態)。**元に戻すときは false にして apply**(FRR は reload)。
  DESC
  type        = bool
  default     = true
}

variable "ionos_link_endpoint" {
  description = "IONOS の、このリンク専用の待ち受けポート(hardware/ionos の gateway_links の listen_port と同じ)"
  type        = string
  default     = "74.208.55.86:51822"
}

variable "ionos_bgp_as" {
  description = "ionosのAS番号(eBGP用)"
  type        = number
  default     = 65030
}

variable "inuyama_asn" {
  description = "k8s2がionosとのeBGPで名乗るAS番号。k8s4(inuyama)の冗長ゲートウェイとして同じASN(65010)を再利用する(同一顧客ASからの複数eBGPセッションはマルチホーミングの一般的な構成)"
  type        = number
  default     = 65010
}

variable "maas_rack_enabled" {
  description = "true にすると、この host(k8s2)に MAAS の Rack コントローラーを導入する(kigawa-net/infra#207、docs/maas-design.md。DHCP の primary の予定)。DHCP は有効にしない(別の段階)。**戻すときは、host の /var/lib/maas-rack-module/maas-rack-rollback.sh を root で実行してから false にする**(false にするだけでは、パッケージは消えない)"
  type        = bool
  default     = true
}

variable "maas_secret_bitwarden_id" {
  description = "MAAS の共有 secret(Region の /var/lib/maas/secret と同じ、32 桁の 16 進数)の Bitwarden の ID(項目名 maas-rack-shared-secret。値ではなく ID)。kigawa-net-k8s の maas-secret(88 文字。MAAS の secret ではない)とは別物。maas_rack_enabled が true のときだけ使う"
  type        = string
  default     = "a7ce1226-55cd-4565-9b61-b4ea00f130f0"
}

variable "maas_rack_lan_address" {
  description = "このホスト(k8s2)の、LAN(192.168.1.0/24)側のアドレス。Rack のポート(TFTP・proxy・NTP・HTTP・syslog)は、この宛先への LAN からの接続だけを許可し、それ以外(VIP 宛て、クラスタのサービス IP 宛て)は DROP する。server_ip(クラスタの LAN のアドレス)とは別"
  type        = string
  default     = "192.168.1.20"
}
