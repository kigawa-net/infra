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
  # 192.168.1.130/32, .150/32, .228/32, .121/32: GitHub Actions(ubuntu-latest)から
  # k8s-worker3/5/1/4へSSH(terraform apply)するための経路(issue #193関連)。
  # 全LANではなく4台の/32のみ。k8s4側(hardware/k8s4 ci_ssh_forward_targets)の
  # tcp/22限定のforward+MASQUERADEと、terraform.ymlのAllowedIPsと必ず揃えること。
  type = list(string)
  default = [
    "172.31.254.1/32",
    "10.0.0.0/24",
    "192.168.1.130/32",
    "192.168.1.150/32",
    "192.168.1.228/32", # k8s-worker1(2026-10-05: node-dns を IaC で適用するため)
    "192.168.1.121/32", # k8s-worker4(同上)
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

variable "k8s1_wireguard_public_key" {
  description = "k8s1 の WireGuard 公開鍵(IONOS 用)。静的な値で持つ(公開鍵は変わらない公開情報)。空文字にすると、ピアと BGP neighbor を無効化する。以前は、CI から k8s1 に SSH して取得し、失敗すると空文字になって、ピアが黙って外れた(2026-10-05、k8s2 のダウン中の apply で、k8s2 のピアが外れ、CI の経路が壊れた)。値は、k8s1 の /etc/wireguard/publickey と、IONOS の wg show で一致を確認した"
  type        = string
  default     = "HZ5NneXNytqEanGjJSLDE5ncHk440O2fXxUmXDyOKDw="

  validation {
    condition     = var.k8s1_wireguard_public_key == "" || can(regex("^[A-Za-z0-9+/]{43}=$", var.k8s1_wireguard_public_key))
    error_message = "k8s1_wireguard_public_key は、空文字か、WireGuard の公開鍵(44 文字の base64)にしてください。"
  }
}

variable "k8s2_wireguard_address" {
  description = "k8s2 の WireGuard IP (AllowedIPs)"
  type        = string
  default     = "172.31.254.12"
}

variable "k8s2_wireguard_public_key" {
  description = "k8s2 の WireGuard 公開鍵(IONOS 用)。静的な値で持つ(公開鍵は変わらない公開情報)。空文字にすると、ピアと BGP neighbor を無効化する。以前は、CI から k8s2 に SSH して取得し、失敗すると空文字になって、ピアが黙って外れた(2026-10-05、k8s2 のダウン中の apply で、k8s2 のピアが外れ、CI の経路が壊れた)。値は、k8s2 の /etc/wireguard/publickey と、IONOS の wg show で一致を確認した"
  type        = string
  default     = "+PuboGsR5IW7ODJ+h7tKXfaeQeTZyC9dsGJPBKos+iY="

  validation {
    condition     = var.k8s2_wireguard_public_key == "" || can(regex("^[A-Za-z0-9+/]{43}=$", var.k8s2_wireguard_public_key))
    error_message = "k8s2_wireguard_public_key は、空文字か、WireGuard の公開鍵(44 文字の base64)にしてください。"
  }
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

# --- Oracle Cloud (バックアップネットワークハブ) ---
# IONOS <-> Oracle間を直接WireGuard/BGP接続し、Inuyama<->IONOS間のリンクが
# 落ちた場合でもIONOS配下(k8s1/k8s2/soichiro)がOracle経由でInuyamaへの
# 経路を確保できるようにする冗長パス。oracle_wireguard_public_keyが空文字の
# 間はpeer/BGPネイバーとも無効化される安全弁(kigawa-net/infra hardware/k8s4の
# oracle_wireguard_public_keyと同じパターン)。
variable "oracle_wireguard_public_key" {
  description = "Oracle の WireGuard 公開鍵。未設定(空文字)の間はOracleピアとBGPネイバーを無効化する安全弁"
  type        = string
  default     = "Jk/0cuz61srFyQNsCu5GXim12tjk9Fp/ttlrCpxMhVg="
}

variable "oracle_wireguard_endpoint" {
  description = "Oracle の WireGuard エンドポイント (IP:port)。IONOS側からOracleへダイヤルする"
  type        = string
  default     = "161.33.138.252:51820"
}

variable "oracle_wireguard_address" {
  description = "Oracle の IONOS側WireGuardトンネル内IP (k8s1=.11, k8s2=.12, soichiro=.13 に続く採番)"
  type        = string
  default     = "172.31.254.14"
}

variable "oracle_home_subnet" {
  description = "Oracle自身のWireGuardホームサブネット (Inuyama<->Oracle間で使われているもの)。IONOS<->Oracle間のAllowedIPsに含め、Oracle宛の中継を可能にする"
  type        = string
  default     = "172.31.253.0/24"
}

variable "oracle_asn" {
  type    = number
  default = 65040
}

variable "firewall_ssh_port" {
  type    = number
  default = 22
}
variable "kigawa_net_k8s_ci_runner_wireguard_public_key" {
  description = "kigawa-net-k8sのGitHub Actions(ubuntu-latest)がPRのdry-run CI(kubectl apply --dry-run=server)実行時に、k8s.kigawa.net(10.0.0.100:6443)へ到達するために一時的にWireGuard接続するためのピア公開鍵。他のci_runner_wireguard_*/kigawa_infra_ci_runner_wireguard_*とは別の専用ピア(同じピアを共用すると複数CIの同時実行で接続元IPの奪い合いにより不安定になるため)。秘密鍵はBitwarden(ci-github-actions-wireguard-private-key, id: 80c81732-ff0b-4859-b6bb-b4d4009fa5ef)で管理"
  type        = string
  default     = "g0BfQ6y8e4f90F8JTn7jsj9i72HMckHhVY21D0yz6Uc="
}

variable "kigawa_net_k8s_ci_runner_wireguard_address" {
  description = "kigawa-net-k8s CI runner の WireGuard IP (AllowedIPs)"
  type        = string
  default     = "172.31.254.22"
}

# Soichiro(Karmada の etcd #2 / control plane を置く別拠点の VM)。Soichiro 側から IONOS へ発信する静的ピア。
# 公開鍵は静的な値で持つ(bws の一時的な 503 で PublicKey が空になり wg0 が止まった 2026-10-03 の事故の再発防止)。
# 空文字にすると、ピアと BGP neighbor は追加されない。
variable "soichiro_wireguard_public_key" {
  description = "Soichiro VM の WireGuard 公開鍵(IONOS 用)。空文字でピアと BGP neighbor を無効化する"
  type        = string
  default     = "pa4k7e3L+pccP9PwaM374CUZKmWU1MGkMrNa+rrkBHs="

  validation {
    condition     = var.soichiro_wireguard_public_key == "" || can(regex("^[A-Za-z0-9+/]{43}=$", var.soichiro_wireguard_public_key))
    error_message = "soichiro_wireguard_public_key は、空文字か、WireGuard の公開鍵(44文字の base64)にしてください。"
  }
}

variable "soichiro_wireguard_address" {
  description = "Soichiro の IONOS 側 WireGuard トンネル内 IP (k8s1=.11, k8s2=.12, 旧soichiro=.13, oracle=.14 に続く採番)"
  type        = string
  default     = "172.31.254.15"
}

variable "soichiro_asn" {
  type    = number
  default = 65020
}

variable "soichiro_accepted_prefixes" {
  description = "Soichiro から受け取る prefix(管理 IP の /32 のみ)。WireGuard の AllowedIPs にも入れ、IONOS-OUT で Inuyama(k8s4)へ再広告する"
  type        = list(string)
  default     = ["10.255.10.12/32"]
}

variable "etcd_allowed_sources" {
  description = "IONOS の Karmada etcd #3(2379/2380)に、WireGuard(wg)内から接続してよい送信元。ufw の既存の `deny 2379:2380/tcp`(公開インターネット向け)より前に、これらの allow を挿入する"
  type        = list(string)
  default = [
    "172.31.254.1",  # k8s4(Inuyama)。Inuyama の etcd #1 の通信は、worker のアドレスで届くが、念のため
    "192.168.1.130", # k8s-worker3(etcd #1 の Pod が動く。Pod の外向きは、ノードの IP に変換される)
    "192.168.1.150", # k8s-worker5
    "172.31.254.15", # Soichiro(wg-ionos)
    "10.255.10.12",  # Soichiro(管理 IP)
  ]
}
