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
  description = "Kubernetes minor version (e.g. 1.30)"
  type        = string
  default     = "1.30"
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
  description = "kube-vipがリーダー選出で参照するAPIサーバーIP (VIP喪失時の自己参照デッドロックを避けるため、kube_vip_addressとは別の到達可能なアドレスにすること)。127.0.0.1(自ノードのローカルAPIサーバー)を指定し、外部LB(旧: host1のhaproxy VM)への単一障害点依存を避ける"
  type        = string
  default     = "127.0.0.1"
}

variable "kube_vip_health_peers" {
  description = "kube-vip のヘルス連動で、止める前に確認する、他の control-plane の apiserver (k8s1 / k8s2 の server_ip)。健全なものが 1 つも無ければ止めない (issue #232)"
  type        = list(string)
  default     = ["10.0.0.103", "10.0.0.120"]
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

variable "ionos_wireguard_allowed_ips" {
  description = "k8s4(inuyama)のionos向けwg1トンネルのAllowedIPs。k8s4はeBGPでionosから172.31.254.0/24全体をインポートし(module.bgpのimport_prefixes参照)、soichiro等の他ピア宛トラフィックをこの1本のトンネル経由で中継するゲートウェイ役を担うため、ionos自身の/32だけでなく172.31.254.0/24全体を含める必要がある(/32のみだと、ionosが中継したsoichiro等からの受信パケットの送信元検証やk8s4からsoichiro等への送信がWireGuard自体に拒否される)"
  type        = list(string)
  # 10.255.10.12/32: Soichiro(Karmada の etcd #2 / control plane)の管理 IP。IONOS 経由で届くよう、
  # WireGuard の暗号鍵ルーティングにも含める(含めないと、k8s4 から送ろうとしても WireGuard が拒否する)。
  # BGP で学習した経路(via 172.31.254.2 dev wg1)を使うので、wg-quick が自動生成する
  # カーネル経路(on-link)は、セットアップスクリプトが削除する。
  default = ["172.31.254.0/24", "10.255.10.12/32"]
}

# --- IONOS との専用リンク(kigawa-net/infra#238) ---------------------------------------------------
# wg1(上)は IONOS の wg0 に載っていて、IONOS 側で k8s4 の peer が 10.0.0.0/24 などの AllowedIPs を独占している。そのため、
# k8s2(予備のゲートウェイ)は IONOS 宛に 10.0.0.x を送信元にできず、データプレーンの冗長化が成立しない。
# ゲートウェイごとの専用リンク(peer は IONOS の 1 つだけ、AllowedIPs = 0.0.0.0/0、Table = off)にして、経路は BGP に任せる。
# 鍵は新しく作らない(wg1 と同じ /etc/wireguard/inuyama_private.key。IONOS 側の peer の公開鍵も、そのまま使える)。
variable "ionos_link_interface" {
  description = "IONOS との専用リンクのインターフェース名"
  type        = string
  default     = "wg-ionos-gw"
}

variable "ionos_link_address" {
  description = "IONOS との専用リンクの、k8s4 側のアドレス(172.31.252.0/30 の .2)"
  type        = string
  default     = "172.31.252.2/30"
}

variable "ionos_link_peer_address" {
  description = "IONOS との専用リンクの、IONOS 側のアドレス(BGP の neighbor)"
  type        = string
  default     = "172.31.252.1"
}

variable "ionos_link_endpoint" {
  description = "IONOS の、このリンク専用の待ち受けポート(hardware/ionos の inuyama_gateway_link の listen_port と同じ。IONOS のクラウドパネルのファイアウォールでも許可すること)"
  type        = string
  default     = "74.208.55.86:51821"
}

variable "ionos_link_primary" {
  description = <<-DESC
    k8s4 の IONOS 方面の出口を、専用リンク(wg-ionos-gw)にするか(true)、従来の wg1 のままにするか(false)。
    true: 専用リンクの eBGP から、172.31.254.0/24 と Soichiro の管理 IP(10.255.10.12/32)を取り込み、wg1 の eBGP からは取り込まない。
    切り替え(kigawa-net/infra#238 の段階 3)で true にする。**元に戻すときは false にして apply**(FRR は reload。差分だけ適用)。
  DESC
  type        = bool
  default     = true
}

variable "ionos_bgp_as" {
  type    = number
  default = 65030
}

# --- Oracle Cloud (計画中のバックアップネットワークハブ) ---
# 外部ランブックで計画されている Oracle Cloud 側の WireGuard/BGP ハブ用のプレースホルダ変数。
# Oracle Cloud ホスト自体のプロビジョニングは本リポジトリ/本セッションの外で別途対応中。
# oracle_wireguard_public_key が空文字 "" の間は、main.tf の null_resource.oracle_wireguard は
# count=0 で完全に無効 (no-op) のままとなり、module.bgp の external_bgp_peers にも
# エントリが追加されない。実際のエンドポイント/公開鍵が判明した時点でこれらの値を
# フォローアップ変更で上書きすれば有効化される。
variable "oracle_wireguard_interface" {
  description = "Oracle Cloud hub 向け WireGuard インターフェース名 (今後 wg-ionos/wg-oracle のような意味付きの命名規則に合わせる。既存のwg0/wg1は稼働中のためリネームしない)"
  type        = string
  default     = "wg-oracle"
}

variable "oracle_wireguard_address" {
  description = "Oracle Cloud hub 向け WireGuard インターフェースのアドレス"
  type        = string
  default     = "172.31.253.1/24"
}

variable "oracle_wireguard_public_key" {
  description = "Oracle の WireGuard 公開鍵 (cat /etc/wireguard/oracle_public.key で取得)。未設定(空文字)の間はoracle_wireguardリソースとBGPピアを無効化する安全弁"
  type        = string
  default     = "Jk/0cuz61srFyQNsCu5GXim12tjk9Fp/ttlrCpxMhVg="
}

variable "oracle_wireguard_endpoint" {
  description = "Oracle の WireGuard エンドポイント (IP:port)"
  type        = string
  default     = "161.33.138.252:51820"
}

variable "oracle_wireguard_allowed_ips" {
  description = "k8s4(inuyama)のoracle向けwg-oracleトンネルのAllowedIPs。OracleはIONOSと同様、soichiro等の他ピア宛トラフィックを中継するゲートウェイ役を担うため、ionos_wireguard_allowed_ipsと同じ理由でOracle自身の/32だけでなく172.31.253.0/24全体を含める必要がある(/32のみだと、Oracleが中継したsoichiro(172.31.253.13)宛の送信がWireGuard自体に'Required key not available'で拒否される。実機で確認・修正)"
  type        = list(string)
  # 10.255.10.12/32: Soichiro の管理 IP。k8s4 が BGP(Oracle 経由)で学習した経路で送れるよう、
  # WireGuard の暗号鍵ルーティングにも含める(含めないと 'Required key not available' で拒否される。
  # 2026-10-04、hardware/k8s4 の IONOS 向け ionos_wireguard_allowed_ips と同じ修正)。
  default = ["172.31.253.0/24", "10.255.10.12/32"]
}

variable "oracle_wireguard_routes" {
  description = "wg-oracle の起動時(PostUp)に、`ip route replace` で、wg-oracle 経由に固定する経路。Soichiro の管理 IP を、Oracle 経由(約 12 ms。IONOS 経由は約 354 ms の予備)で送る。wg-quick の AllowedIPs からの自動経路(Table = off で止めてある)の代わり。replace なので、wg1 の AllowedIPs に同じ 10.255.10.12/32 があっても、起動順で衝突しない(2026-10-18、wg1 が先に経路を取り、wg-oracle が 4 日間、起動できなかった)"
  type        = list(string)
  default     = ["10.255.10.12/32"]
}

variable "oracle_bgp_as" {
  description = "Oracle Cloud hub のAS番号"
  type        = number
  default     = 65040
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

# kigawa-net/infra#178: 旧名称"alice"は廃止済みの外部VPSゲートウェイの名残。
# 実際には現在ionos(hardware/ionosのinuyama_ingress_vip/minecraft_backend_vip)
# からの転送先として使われている現役のインフラのため、gateway_*に改名した。
# null_resource.inuyama_gateway_servicesのコメント参照。
variable "gateway_metallb_namespace" {
  type    = string
  default = "metallb-system"
}

variable "gateway_metallb_pool_name" {
  type    = string
  default = "main-pool"
}

variable "gateway_metallb_base_range" {
  type    = string
  default = "10.0.0.50-10.0.0.99"
}

variable "gateway_metallb_reserved_range" {
  type    = string
  default = "10.0.0.240-10.0.0.249"
}

variable "gateway_ingress_vip" {
  type    = string
  default = "10.0.0.240"
}

variable "gateway_minecraft_vip" {
  type    = string
  default = "10.0.0.241"
}

variable "ci_runner_wireguard_address" {
  description = "kigawa-net/infra CIランナー(GitHub Actions ubuntu-latest)のWireGuard IP。hardware/ionosのkigawa_infra_ci_runner_wireguard_addressと同じ値"
  type        = string
  default     = "172.31.254.21"
}

variable "ci_ssh_forward_targets" {
  description = "CIランナーからwg1経由でSSH(tcp/22)のみ中継を許可する自宅LAN上のworkerのIP(k8s-worker3/k8s-worker5/k8s-worker1/k8s-worker4)。ionosのwireguard_peer_allowed_ipsの/32と揃えること"
  type        = list(string)
  default     = ["192.168.1.130", "192.168.1.150", "192.168.1.228", "192.168.1.121"]
}

variable "lan_interface" {
  description = "k8s4の自宅LAN側NIC(192.168.1.120を持つインターフェース)"
  type        = string
  default     = "ens18"
}

variable "etcd_peer_masquerade_source_cidr" {
  description = "Karmada の etcd #1(worker3 の Pod)の通信が、k8s4 に届くときの送信元(worker の LAN)。この送信元から Soichiro 宛の etcd の通信を、k8s4 の WireGuard の出口で MASQUERADE する"
  type        = string
  default     = "192.168.1.0/24"
}

variable "etcd_peer_masquerade_destinations" {
  description = "MASQUERADE の対象にする宛先(Soichiro の管理 IP)。Soichiro は 192.168.1.0/24 への戻りの経路を持たないため、送信元を k8s4 の WireGuard のアドレスに書き換えないと、SYN-ACK が戻れない。IONOS(172.31.254.2)は、192.168.1.130/32・.150/32 を wg0 で持っているため、対象にしない"
  type        = list(string)
  default     = ["10.255.10.12"]
}

variable "maas_rack_enabled" {
  description = "true にすると、この host(k8s4)に MAAS の Rack コントローラーを導入する(kigawa-net/infra#207、docs/maas-design.md。DHCP の secondary の予定)。DHCP は有効にしない(別の段階)。**戻すときは、host の /var/lib/maas-rack-module/maas-rack-rollback.sh を root で実行してから false にする**(false にするだけでは、パッケージは消えない)。k8s4 は IONOS の主ゲートウェイなので、導入の前後で、IONOS との接続を確認する"
  type        = bool
  default     = true
}

variable "maas_secret_bitwarden_id" {
  description = "MAAS の共有 secret(Region の /var/lib/maas/secret と同じ、32 桁の 16 進数)の Bitwarden の ID(項目名 maas-rack-shared-secret。値ではなく ID)。kigawa-net-k8s の maas-secret(88 文字。MAAS の secret ではない)とは別物。maas_rack_enabled が true のときだけ使う"
  type        = string
  default     = "a7ce1226-55cd-4565-9b61-b4ea00f130f0"
}

variable "maas_rack_lan_address" {
  description = "このホスト(k8s4)の、LAN(192.168.1.0/24)側のアドレス。Rack のポート(TFTP・proxy・NTP・HTTP・syslog)は、この宛先への LAN からの接続だけを許可し、それ以外(VIP 宛て、クラスタのサービス IP 宛て)は DROP する。server_ip(クラスタの LAN のアドレス)とは別"
  type        = string
  default     = "192.168.1.120"
}
