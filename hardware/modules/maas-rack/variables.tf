variable "host" {
  type = string
}

variable "ssh_user" {
  type = string
}

variable "ssh_private_key" {
  type      = string
  sensitive = true
}

variable "sudo_password" {
  type      = string
  sensitive = true
}

variable "enabled" {
  description = "true にすると、この host に MAAS の Rack コントローラーを導入する。既定は false(何もしない)。control-plane への導入は、1 台ずつ、別の PR で true にする"
  type        = bool
  default     = false
}

variable "maas_url" {
  description = <<-DESC
    Rack が登録する Region の URL。**Region 専用の LoadBalancer Service の固定の VIP(10.0.0.244。kigawa-net-k8s の maas/region-lb.yaml)を使う。**
    maas-agent は、この URL のホスト(agent.yaml の controllers)の tcp 5271(Region の Temporal)に接続する。以前の Ingress の URL(https://maas.kigawa.net/MAAS。
    ホストは Ingress の VIP 10.0.0.240 で、80/443 しか公開しない)では、maas-agent が connection refused で、約 1 分ごとにクラッシュと再起動を繰り返した。
    IP で指定するので、DNS の変更は要らない。Pod が作り直されても、VIP は変わらない。
  DESC
  type        = string
  default     = "http://10.0.0.244:5240/MAAS"
}

variable "maas_version" {
  description = <<-DESC
    Rack の MAAS のバージョン(major.minor。PPA ppa:maas/<version>)。**Region(kigawa-net-k8s の maas/region.yaml)と同じか、古いバージョンにする**(Rack は Region より新しくできない)。
    すでに別のバージョンが入っている host では、files/maas-rack-upgrade.sh が、この版に上げる(下げる方向は中止)。
    **既定値は無い(必須)。** 呼び出し側(hardware/k8s2、hardware/k8s4)が、host ごとに明示する。DHCP の failover の 2 台を、同時に更新しないため、1 台ずつ、別の PR で上げる。
    3.7 にした理由: Region を 3.7 に上げたため。3.6 の Rack は、3.7 の Region が出す Temporal のタスク(delete-bootresource など)を処理できず、OS イメージの取り込みが完了しない(kigawa-net/infra#317)。
  DESC
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.maas_version))
    error_message = "maas_version は major.minor の形(例: 3.7)にしてください。"
  }
}

variable "maas_secret" {
  description = "Region との共有 secret(Bitwarden から取得した値)。enabled が false のときは、使われない(空でよい)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "min_available_mb" {
  description = "導入前に必要な、メモリの空き(MB)。これを下回る host には、導入しない(k8s1 は 541MB で、足りない)"
  type        = number
  default     = 2000

  validation {
    condition     = var.min_available_mb >= 1000
    error_message = "min_available_mb は 1000 以上にする(control-plane を逼迫させないため)。"
  }
}

variable "lan_cidr" {
  description = "Rack のポート(TFTP・proxy・NTP・HTTP・syslog)への接続を許可する、LAN の送信元(CIDR)。それ以外の送信元は DROP する(files/maas-rack-firewall.sh)"
  type        = string
  default     = "192.168.1.0/24"

  validation {
    condition     = can(cidrhost(var.lan_cidr, 0))
    error_message = "lan_cidr は、CIDR で指定する(例: 192.168.1.0/24)。"
  }
}

variable "lan_address" {
  description = "このホストの、LAN 側のアドレス(例: k8s2 は 192.168.1.20)。Rack のポートは、この宛先への接続だけを許可する(VIP 宛て、クラスタのサービス IP 宛ては、DROP)。host(SSH の接続先)とは別。enabled が true のときは、必須"
  type        = string
  default     = ""

  validation {
    condition     = var.lan_address == "" || can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", var.lan_address))
    error_message = "lan_address は、IPv4 のアドレスで指定する(例: 192.168.1.20)。"
  }
}

variable "dhcp_peer_address" {
  description = "DHCP の failover の相手(もう一方の Rack)の、LAN 側のアドレス(例: k8s2 なら 192.168.1.120)。ファイアウォールで、このアドレスから、failover のポート(tcp 647 / 7911)への接続だけを許可する。空なら、許可しない。DHCP を有効にするまでは、待ち受けが無いので、影響は無い"
  type        = string
  default     = ""

  validation {
    condition     = var.dhcp_peer_address == "" || can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", var.dhcp_peer_address))
    error_message = "dhcp_peer_address は、IPv4 のアドレスで指定する(例: 192.168.1.120)。"
  }
}

variable "wol_webhook_enabled" {
  description = "true にすると、MAAS 用の Wake on LAN の webhook(files/maas-wol-webhook.py。127.0.0.1:5290)を、この Rack に入れる。MAAS には WoL の電源ドライバが無く、webhook ドライバで、このサービスを呼ぶ(kigawa-net/infra#316、#317)"
  type        = bool
  default     = true
}

variable "wol_webhook_port" {
  description = "WoL の webhook の待ち受けポート(127.0.0.1 だけ)"
  type        = number
  default     = 5290
}

variable "wol_broadcast" {
  description = "マジックパケットの宛先(LAN のブロードキャストアドレス)。空なら、lan_cidr の最後のアドレス(192.168.1.0/24 なら 192.168.1.255)"
  type        = string
  default     = ""
}

variable "wol_shutdown_targets" {
  description = <<-DESC
    MAAS の /off で、SSH により shutdown するノード(kigawa-net/infra#416)。既定は空(何もしない。/off は unsupported のまま)。
    キーは MAC(小文字・コロン区切り)、host は対象の IPv4、user は対象ノードの専用ユーザー(k8s-worker5 の maas-shutdown)。
    wol_shutdown_private_key・wol_shutdown_known_hosts・wol_shutdown_auth_token と**4 つそろえて**指定する(一部だけは plan で失敗する)。wol_webhook_enabled = true のときだけ有効。
    ノード側の受け口は、hardware/k8s-worker5 の maas_shutdown_public_key(別の PR で設定する)。
  DESC
  type = map(object({
    host = string
    user = string
  }))
  default = {}

  validation {
    condition     = alltrue([for mac in keys(var.wol_shutdown_targets) : can(regex("^([0-9a-f]{2}:){5}[0-9a-f]{2}$", mac))])
    error_message = "wol_shutdown_targets のキーは、小文字・コロン区切りの MAC にする(例: 02:39:7a:2e:13:f0)。"
  }

  validation {
    condition     = alltrue([for t in values(var.wol_shutdown_targets) : can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", t.host))])
    error_message = "wol_shutdown_targets の host は、IPv4 のアドレスで指定する(例: 192.168.1.150)。"
  }

  validation {
    condition     = alltrue([for t in values(var.wol_shutdown_targets) : can(regex("^[a-z_][a-z0-9_-]{0,31}$", t.user))])
    error_message = "wol_shutdown_targets の user は、小文字で始まる Unix のユーザー名にする(先頭の - は不可)。"
  }
}

variable "wol_shutdown_private_key" {
  description = "/off で SSH するときの秘密鍵(OpenSSH 形式、パスフレーズ無し)。値は Bitwarden などから渡す(この module は取得しない。保管先は別 issue)。空なら何もしない"
  type        = string
  sensitive   = true
  default     = ""
}

variable "wol_shutdown_known_hosts" {
  description = "/off で SSH するノードのホスト公開鍵の行(known_hosts の形式。例: ssh-keyscan -t ed25519 <host> の出力)。StrictHostKeyChecking=yes で使う。空なら何もしない。取り方は README"
  type        = string
  default     = ""
}

variable "wol_shutdown_auth_token" {
  description = <<-DESC
    MAAS の webhook 電源ドライバが送る Bearer トークン(power_token)と、同じ値。/off は、これが一致するときだけ実行する(kigawa-net/infra#417)。
    32 文字以上の [A-Za-z0-9._~+/=-]。既定は空(何もしない)。表が空の構成では不要。表があるのにトークンが無い Rack は、/off に 503 を返す(fail closed)。
    MAAS 側への設定の手順は README(トークンを画面・履歴に出さない方法を含む)。
  DESC
  type        = string
  sensitive   = true
  default     = ""

  validation {
    condition     = var.wol_shutdown_auth_token == "" || can(regex("^[A-Za-z0-9._~+/=-]{32,}$", var.wol_shutdown_auth_token))
    error_message = "wol_shutdown_auth_token は、32 文字以上の [A-Za-z0-9._~+/=-] のみ。"
  }
}
