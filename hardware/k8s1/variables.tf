variable "host" {
  type    = string
  default = "192.168.1.103"
}

variable "server_ip" {
  type    = string
  default = "10.0.0.103"
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

variable "pod_network_cidr" {
  description = "Pod network CIDR passed to kubeadm init (Flannel default: 10.244.0.0/16)"
  type        = string
  default     = "10.244.0.0/16"
}

variable "cni_manifest_url" {
  description = "CNI manifest URL applied after kubeadm init"
  type        = string
  default     = "https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml"
}

variable "control_plane_host" {
  description = "既存control-planeのSSHホスト。空の場合はkubeadm initを実行し、設定されている場合はclusterが存在すればjoinする"
  type        = string
  default     = "k8s4"
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
  default     = ["10.0.0.120", "10.0.0.140"]
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
  description = "kube-vip のヘルス連動で、止める前に確認する、他の control-plane の apiserver (k8s2 / k8s4 の server_ip)。健全なものが 1 つも無ければ止めない (issue #232)"
  type        = list(string)
  default     = ["10.0.0.120", "10.0.0.140"]
}

variable "kube_vip_enabled" {
  description = "falseにするとこのノードのkube-vipを撤去し、リーダー選出/BGP VIP広報から除外する (ローカルディスクI/O障害等でapiserverがクラッシュループしている間の一時的な緩和策用)"
  type        = bool
  default     = true
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
  default     = "172.31.255.11/24"
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
  default     = "172.31.254.11/32"
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
  description = "WireGuard トンネル経由でルーティングする IP レンジ (Ionos hub)。ionos自身の/32のみにする(172.31.254.0/24全体にすると、soichiro等の他ピア宛のトラフィックも直接このトンネル経由で送ろうとしてしまい、ionos側のAllowedIPsチェック(送信元スプーフィング防止)で破棄される。他ピア宛はBGP経由(k8s4/inuyama)で正しくルーティングされる)"
  type        = list(string)
  default     = ["172.31.254.2/32"]
}

# EasyTier(kigawa-net/infra#390、docs/network-vpn-architecture-design.md §4.1)。
# false のときは、何も作らず、Bitwarden にも触れない(plan は no-op)。有効化は 1 台ずつ、別の PR で行う。
variable "easytier_enabled" {
  description = "true のときだけ EasyTier を入れる(NAT 配下のノードとして、公開 Peer 2 台へ接続する)"
  type        = bool
  default     = false
}

variable "easytier_network_secret_bitwarden_id" {
  description = "EasyTier のネットワーク Secret の bws の ID(easytier-network-secret)。ionos・bao-02・bao-03 と同じ値"
  type        = string
  default     = "698da56c-a169-4837-93a1-b4f00107b513"
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
  description = "このノードの EasyTier の Overlay アドレス(設計書 §4.1。k8s4 が Inuyama Gateway の 10.250.0.11)"
  type        = string
  default     = "10.250.0.12/24"
}

variable "easytier_peers" {
  description = "初期接続先の公開 Peer(ServerCheap = bao-02 と IONOS)。特定の 1 台だけに依存しない"
  type        = list(string)
  default     = ["tcp://207.231.111.196:11010", "tcp://74.208.55.86:11010"]
}

variable "easytier_overlay_allow" {
  description = "EasyTier の Overlay(10.250.0.0/24)からの受信を許可するポート。既定は空で、Overlay からは何も受けない(ICMP を除く)。control-plane は ufw を使わないので、iptables で絞る(modules/easytier の overlay_iptables_firewall)。Overlay の他ノードから 6443・10250・etcd に届かないようにする(設計書 §7)"
  type        = list(string)
  default     = []
}
