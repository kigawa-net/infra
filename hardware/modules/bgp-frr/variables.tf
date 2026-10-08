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

variable "stop_bird" {
  description = "FRR起動前にBIRD static Pod manifestを削除する"
  type        = bool
  default     = false
}

variable "bgp_router_id" {
  description = "FRRのrouter ID (通常はノードのIP)"
  type        = string
}

variable "bgp_local_as" {
  description = "Inuyamaサイト(ローカル)のAS番号"
  type        = number
  default     = 65000
}

variable "bgp_peers" {
  description = "iBGPピアのIPリスト (全て同じAS番号を使用)"
  type        = list(string)
  default     = []
}

variable "ibgp_keepalive_seconds" {
  description = <<-EOT
    iBGP ピア(bgp_peers)の keepalive 間隔(秒)。null のときは timers を設定せず、FRR の既定(60 秒)のまま。
    ホールドタイム(ibgp_hold_seconds)とセットで指定する。外部の eBGP ピア(external_bgp_peers)には適用しない
    (WAN の遅延や一時的な揺れでセッションが切れるのを避けるため)。
  EOT
  type        = number
  default     = null

  # 変数の validation は、Terraform 1.9 未満では、ほかの変数を参照できない(CI で失敗した)。
  # この変数だけで確かめられる範囲に絞り、keepalive と hold の関係は、main.tf の precondition で確かめる。
  validation {
    condition     = var.ibgp_keepalive_seconds == null || var.ibgp_keepalive_seconds >= 1
    error_message = "ibgp_keepalive_seconds は 1 以上にすること(または null)。"
  }
}

variable "ibgp_hold_seconds" {
  description = <<-EOT
    iBGP ピア(bgp_peers)のホールドタイム(秒)。null のときは timers を設定せず、FRR の既定(180 秒)のまま。
    BGP デーモンごと、または OS ごと止まったノードの経路を、この時間で撤回する(issue #232)。
    keepalive の 3 倍以上にする(BGP の慣例)。短くしすぎると、負荷で bgpd が一時的に遅れただけで、
    セッションが切れて経路が揺れる。
  EOT
  type        = number
  default     = null

  validation {
    condition     = var.ibgp_hold_seconds == null || var.ibgp_hold_seconds >= 3
    error_message = "ibgp_hold_seconds は 3 以上にすること(または null)。BGP のホールドタイムは 0 か 3 以上。"
  }
}

variable "kube_vip_as" {
  description = "kube-vipのAS番号 (FRRと区別するため別ASを使用)"
  type        = number
  default     = 65001
}

variable "enable_kube_vip_peer" {
  description = <<-EOT
    同一ホストの kube-vip と BGP を張る(127.0.0.2 <-> 127.0.0.1)設定を出力する。既定は無効。
    隔離環境の FRR 8.4.7 での検証(2026-10-05)で、この構成は動かないと分かった:
    - 127.0.0.x は BGP の自分側アドレスに使えない(nexthop_set failed, intf Unknown)。
    - 自ノードのインターフェースにあるアドレスは neighbor に指定できない。
    - 動的ネイバー(bgp listen range)+ lo の非127アドレスなら確立するが、kube-vip が送る next-hop は
      自ノードのアドレスのため、受信時に "martian or self next-hop" で破棄される(allow-martian-nexthop でも解消しない)。
    API VIP(10.0.0.100/32)は、保持ノードのインターフェースに直結として存在するため、
    redistribute_connected_prefixes で伝搬する想定。READMEの未決事項を参照。
  EOT
  type        = bool
  default     = false
}

variable "advertised_vips" {
  description = "BGP経由で広告するVIPのIPリスト (各ノードのloopbackに追加してnetworkで広告)"
  type        = list(string)
  default     = []
}

variable "redistribute_connected_prefixes" {
  description = <<-EOT
    直結(connected)経路のうち、BGPへ再配布するprefixの完全一致リスト。
    BIRDの protocol direct は直結経路を全てBGPテーブルへ入れていたが、FRRでは許可リスト方式にする。
    実機(2026-10-05)で必要と確認したもの: 10.0.0.0/24(k8s4がIONOS/Oracleへ広告)、
    10.0.0.100/32(kube-vipのAPI VIP。保持ノードのインターフェースに直結として存在する)、
    10.0.0.254/32(keepalivedのゲートウェイVIP)。
  EOT
  type        = list(string)
  default     = []
}

variable "ionos_nexthop_helper_interface" {
  description = "互換性のため保持。FRRでのnext-hop専用経路の扱いは未決のため空文字列のみ許可する"
  type        = string
  default     = ""

  validation {
    condition     = var.ionos_nexthop_helper_interface == ""
    error_message = "FRRのnext-hop helperは未実装です。カーネル経路への影響を検証するまで空文字列にしてください。READMEの未決事項を参照してください。"
  }
}

variable "external_bgp_peers" {
  description = "eBGP peers with explicit prefix filters. Used for site-to-site peers outside the Inuyama iBGP mesh."
  type = list(object({
    local_ip        = string
    local_as        = number
    neighbor_ip     = string
    neighbor_as     = number
    import_prefixes = list(string)
    export_prefixes = list(string)
    # import した経路に付ける local-pref(大きいほど優先)。null の間は設定しない(BIRD の既定値のまま)。
    # 複数の外部ピアから同じ宛先を学習するとき(例: IONOS 経由と Oracle 経由)に、優先する経路を決める。
    local_pref = optional(number)
  }))
  default = []
}
