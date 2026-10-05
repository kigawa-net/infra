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

variable "kube_vip_as" {
  description = "kube-vipのAS番号 (FRRと区別するため別ASを使用)"
  type        = number
  default     = 65001
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
