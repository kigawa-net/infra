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
