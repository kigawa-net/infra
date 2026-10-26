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
  # wg0 の k8s4(Inuyama)の peer の AllowedIPs。
  #
  # **縮めないこと**(kigawa-net/infra#238、2026-10-12 の障害): 10.0.0.0/24 と worker の /32 を外して `172.31.254.1/32` だけに縮めると、
  # IONOS → Inuyama の通信が、片方向になる。理由: IONOS 発の通信は、BGP の経路(専用リンク wg-gw4)で k8s4 に届くが、k8s4 の
  # 戻りは、`172.31.254.2` への直結の経路(`172.31.254.0/30 dev wg1`、BGP の `/24` より長いプレフィックス)で、wg1 から出る。
  # IONOS は、wg1 から届いた、送信元 10.0.0.x のパケットを、wg0 の k8s4 の peer の AllowedIPs で受け入れるかを判定するので、
  # AllowedIPs に 10.0.0.0/24 が無いと、WireGuard が破棄する(非対称経路。約 33 分間、IONOS の HAProxy・etcd #3・Karmada の
  # Inuyama 向けの通信が、返信を受け取れなかった)。つまり、wg0 の AllowedIPs は、「経路」ではなく「受信の許可」としても必要。
  #
  # 経路(カーネル)だけを BGP に移すには、AllowedIPs を縮めず、wg-quick が AllowedIPs から作る `10.0.0.0/24 dev wg0` などの
  # カーネルの経路(距離 0。BGP の距離 20 に勝つ)だけを消す: 切り替え済み(2026-10-12。cutover_ionos.sh)。ただし、wg0 を
  # **再起動すると、これらの経路が復活し、経路が wg0 に戻る**(疎通は維持される。BGP の経路は壊れない)。恒久的に防ぐには、
  # wg0 に `Table = off` を入れて、AllowedIPs 由来の経路を作らせない(wg0 の再起動と、必要な経路の PostUp での追加が要る。別の変更)。
  #
  # 192.168.1.130/32, .150/32, .228/32, .121/32: GitHub Actions(ubuntu-latest)から k8s-worker3/5/1/4 へ SSH(terraform apply)する
  # ための経路(issue #193関連)。切り替え後は、専用リンクの静的経路(inuyama_gateway_link.static_routes)で運ぶ。そちらと、
  # k8s4 側(hardware/k8s4 ci_ssh_forward_targets)の tcp/22 限定の forward + MASQUERADE と、terraform.yml の AllowedIPs と
  # 必ず揃えること。
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
  default     = "+KoPyNaB89BSLsyDFsKPz4+SsAGjQW1LpbXqSiTeigI="

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

# bao-02(OpenBao の raft voter。IONOS とは別の VPS、207.231.111.196)。spoke として IONOS へ発信する(endpoint なし)。
# 公開鍵は bao-02 の初回 apply 後に、そのホストの /etc/wireguard/publickey から読んで設定する。
# 空文字のままの間は、ピアを出さない(hardware/bao-02 の apply だけでは、IONOS の wg0 は変わらない)。
variable "bao02_wireguard_public_key" {
  description = "bao-02 の WireGuard 公開鍵(IONOS 用)。bao-02 の初回 apply の後、ホストの /etc/wireguard/publickey を読んで設定する。空文字のままは、ピアを出さない"
  type        = string
  default     = ""

  validation {
    condition     = var.bao02_wireguard_public_key == "" || can(regex("^[A-Za-z0-9+/]{43}=$", var.bao02_wireguard_public_key))
    error_message = "bao02_wireguard_public_key は、空文字か、WireGuard の公開鍵(44文字の base64)にしてください。"
  }
}

variable "bao02_wireguard_address" {
  description = "bao-02 の IONOS 側 WireGuard トンネル内 IP(hardware/bao-02 の wg_address と一致させる。k8s1=.11, k8s2=.12, soichiro=.15, oracle=.14 に続く採番)"
  type        = string
  default     = "172.31.254.30"
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

# --- ゲートウェイごとの専用リンク(kigawa-net/infra#238) -----------------------------------------
# wg0 は 1 つのインターフェースに多数の peer を載せるため、同じプレフィックスを複数の peer の AllowedIPs に割り当てられない
# (k8s4 が 10.0.0.0/24 を持つと、k8s2 は IONOS 宛に 10.0.0.x を送信元にできない)。ゲートウェイごとに専用のインターフェース
# (peer は 1 つ、AllowedIPs = 0.0.0.0/0、Table = off)を作り、経路は BGP(FRR)に任せる。
# 鍵は新しく作らない。IONOS の既存の鍵(/etc/wireguard/ionos_private.key)を共有し、peer も既存の公開鍵を使う。
variable "wg0_inuyama_local_pref" {
  description = <<-DESC
    wg0 経由の k8s4 / k8s2 の neighbor(172.31.254.1、172.31.254.12)から学ぶ経路の BGP の local-preference。
    専用リンク(gateway_links の local_pref。200 / 150)より小さくして、専用リンク経由の経路を、必ず優先する
    (wg0 のカーネルの経路を消したとき、古い wg0 経由の経路が best になって、wg0 に戻ることを防ぐ)。Oracle・Soichiro は設定しない(既定の 100)。
  DESC
  type        = number
  default     = 50

  validation {
    condition     = var.wg0_inuyama_local_pref >= 1 && var.wg0_inuyama_local_pref < 100 && var.wg0_inuyama_local_pref == floor(var.wg0_inuyama_local_pref)
    error_message = "wg0_inuyama_local_pref は、1〜99 の整数(専用リンクの local_pref より小さく)にしてください。"
  }
}

variable "inuyama_gateway_link" {
  description = <<-DESC
    k8s4(Inuyama の主のゲートウェイ)との専用リンク(`wg-gw4`)。公開鍵は、`wg0` の k8s4 の peer と同じ(Bitwarden 由来の
    data.external.inuyama_wireguard_public_key)。null にすると、リンクを作らない。
      name         : WireGuard のインターフェース名(wg-gw で始まる)
      address      : IONOS 側のアドレス(/30)
      listen_port  : IONOS の待ち受けポート(51821 以上。gateway_links の listen_port と別)
      peer_address : k8s4 側のトンネル内アドレス(BGP の neighbor)
      local_pref   : このリンクから学ぶ経路の BGP の local-preference(既定 200。k8s2 のリンクは 150 の予備。大きいほど優先)
      static_routes: k8s4 経由で届く、固定のホスト(/32)。リンクの PostUp で、`via <peer_address> dev <name> metric 100` の
                     静的経路として、事前に置く。今は、wg0 の k8s4 の peer の AllowedIPs 由来のカーネルの経路(メトリクス 0)が優先され、
                     影響しない。切り替え(段階 3)で、wg0 側の経路を消すと、この経路に移る。
                     wireguard_peer_allowed_ips の /32(GitHub Actions から worker への SSH の経路)と、必ず揃えること
                     (hardware/k8s4 の ci_ssh_forward_targets とも)。10.0.0.0/24 は、BGP で学ぶので、ここには書かない。
    ポートは、IONOS の VPS のクラウドパネルのファイアウォールでも許可すること(IaC の管理外。51821–51822/udp は許可済み)。
  DESC
  type = object({
    name          = string
    address       = string
    listen_port   = number
    peer_address  = string
    static_routes = optional(list(string), [])
    local_pref    = optional(number, 200)
  })
  default = {
    name         = "wg-gw4"
    address      = "172.31.252.1/30"
    listen_port  = 51821
    peer_address = "172.31.252.2"
    # worker1(228)・worker3(130)・worker4(121)・worker5(150): GitHub Actions(ubuntu-latest)からの terraform apply の SSH の経路
    static_routes = ["192.168.1.130/32", "192.168.1.150/32", "192.168.1.228/32", "192.168.1.121/32"]
  }

  validation {
    # `||` は、右辺の評価エラー(null の属性の参照)を短絡しない。null のときは、try で、条件を評価せずに通す
    condition = var.inuyama_gateway_link == null || try(
      can(regex("^wg-gw[a-z0-9]{1,8}$", var.inuyama_gateway_link.name)) &&
      can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}/30$", var.inuyama_gateway_link.address)) &&
      can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", var.inuyama_gateway_link.peer_address)) &&
      cidrhost(var.inuyama_gateway_link.address, 0) == cidrhost("${var.inuyama_gateway_link.peer_address}/30", 0) &&
      split("/", var.inuyama_gateway_link.address)[0] != var.inuyama_gateway_link.peer_address &&
      var.inuyama_gateway_link.listen_port >= 51821 && var.inuyama_gateway_link.listen_port <= 51899 &&
      var.inuyama_gateway_link.listen_port == floor(var.inuyama_gateway_link.listen_port) &&
      alltrue([for r in var.inuyama_gateway_link.static_routes : can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}/32$", r))]) &&
      var.inuyama_gateway_link.local_pref >= 1 && var.inuyama_gateway_link.local_pref <= 4000000000 &&
      var.inuyama_gateway_link.local_pref == floor(var.inuyama_gateway_link.local_pref),
      false
    )
    error_message = "inuyama_gateway_link は、name が wg-gw*、address が /30、peer_address が同じ /30 の別のアドレス、listen_port が 51821〜51899 の整数、static_routes が /32 の IPv4 のリストにしてください。"
  }
  # gateway_links との name / listen_port の重複は、Terraform 1.9 未満では、validation から他の変数を参照できないため、
  # null_resource.ionos_gateway の precondition で確かめる。
}

variable "gateway_links" {
  description = <<-DESC
    ゲートウェイ(Inuyama の k8s4 / k8s2)との専用リンク。
      name            : WireGuard のインターフェース名(wg-gw で始まる。例: wg-gw2)
      address         : IONOS 側のアドレス(CIDR。/30 の点対点)
      listen_port     : IONOS の待ち受けポート(リンクごとに別。ufw で許可する)
      peer_public_key : 対向の公開鍵(既存の鍵と同じ)
      peer_address    : 対向のトンネル内アドレス(BGP の neighbor)
      peer_asn        : 対向の AS 番号
    stage 1: k8s2(予備)のリンクだけを足す。カーネルの経路(wg0)が主のままなので、データには影響しない。
    アドレスは 172.31.252.0/24(リポジトリ内で未使用)から /30 ずつ: k8s2 = .4/30(IONOS .5、k8s2 .6)、k8s4 = .0/30(IONOS .1、k8s4 .2。stage 3)。
    ポート: k8s4 = 51821、k8s2 = 51822。
    注意: リンクをこのリストから外しても、IONOS 上のインターフェース・設定・ufw のルールは、自動では消えない(手動で
    `systemctl disable --now wg-quick@<name>` と、`/etc/wireguard/<name>.conf` の削除、ufw のルールの削除が要る)。
  DESC
  type = list(object({
    name            = string
    address         = string
    listen_port     = number
    peer_public_key = string
    peer_address    = string
    peer_asn        = number
    static_routes   = optional(list(string), [])
    local_pref      = optional(number, 100)
  }))
  default = [
    {
      name            = "wg-gw2"
      address         = "172.31.252.5/30"
      listen_port     = 51822
      peer_public_key = "+KoPyNaB89BSLsyDFsKPz4+SsAGjQW1LpbXqSiTeigI=" # k8s2(var.k8s2_wireguard_public_key と同じ。鍵は共有する)
      peer_address    = "172.31.252.6"
      peer_asn        = 65010
      local_pref      = 150 # 予備(k8s4 の専用リンクが 200。k8s4 のリンクが落ちると、BGP がこちらに移る)
    },
  ]

  validation {
    condition     = alltrue([for l in var.gateway_links : can(regex("^wg-gw[a-z0-9]{1,8}$", l.name))])
    error_message = "name は wg-gw で始まる英小文字・数字(例: wg-gw2)にしてください。"
  }
  validation {
    condition = alltrue([
      for l in var.gateway_links :
      can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}/30$", l.address)) &&
      can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", l.peer_address)) &&
      try(cidrhost(l.address, 0) == cidrhost("${l.peer_address}/30", 0), false) &&
      try(split("/", l.address)[0] != l.peer_address, false)
    ])
    error_message = "address は /30 の CIDR、peer_address は同じ /30 に入る、address とは別の IPv4 アドレスにしてください。"
  }
  validation {
    condition     = alltrue([for l in var.gateway_links : can(regex("^[A-Za-z0-9+/]{43}=$", l.peer_public_key))])
    error_message = "peer_public_key は、WireGuard の公開鍵(44 文字の base64)にしてください。"
  }
  validation {
    condition     = alltrue([for l in var.gateway_links : l.listen_port >= 51821 && l.listen_port <= 51899 && l.listen_port == floor(l.listen_port)])
    error_message = "listen_port は 51821〜51899 にしてください(wg0 の 51820 とは別)。"
  }
  validation {
    condition     = length(distinct([for l in var.gateway_links : l.name])) == length(var.gateway_links) && length(distinct([for l in var.gateway_links : l.listen_port])) == length(var.gateway_links)
    error_message = "name と listen_port は、リンクごとに別にしてください。"
  }
}
