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

variable "knot_image" {
  type    = string
  default = "cznic/knot:latest"
}

variable "zones" {
  description = "ゾーン名 → ゾーンファイル内容のマップ"
  type        = map(string)
  default     = {}
}

variable "extra_config" {
  description = "knot.conf に追加する設定"
  type        = string
  default     = ""
}
