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

variable "interface" {
  description = "VRRPが動作するネットワークインターフェース"
  type        = string
}

variable "virtual_router_id" {
  description = "VRRPのRouter ID (0-255)"
  type        = number
  default     = 51
}

variable "priority" {
  description = "VRRPの優先度 (高い方がMaster)"
  type        = number
  default     = 100
}

variable "virtual_ip" {
  description = "管理する仮想IPアドレス"
  type        = string
}

variable "auth_pass" {
  description = "VRRPの認証パスワード"
  type        = string
  default     = "secret"
}

variable "state" {
  description = "初期状態 (MASTER or BACKUP)"
  type        = string
  default     = "BACKUP"
}

variable "extra_instances" {
  description = <<-EOT
    追加の VRRP インスタンス(既存の VI_1 の設定は変えない)。#241 の Core Router VIP(192.168.1.200/24)など。
    virtual_ip には prefix を付ける(例: "192.168.1.200/24")。VI_1 とは別の virtual_router_id を使うこと。
    check_core_router が true のインスタンスは、ヘルスチェック(IP 転送が有効で、BGP が :179 で待ち受け中)に
    失敗すると priority が 30 下がり、他のノードに VIP が移る。
  EOT
  type = list(object({
    name              = string
    virtual_router_id = number
    priority          = number
    state             = string
    virtual_ip        = string
    check_core_router = optional(bool, true)
  }))
  default = []
}
