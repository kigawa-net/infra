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
