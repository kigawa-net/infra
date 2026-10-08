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
  description = "false のとき、timer を止めて、メトリクスのファイルを消す(ノードに何も残さない)"
  type        = bool
  default     = true
}

variable "interval_minutes" {
  description = "検知の間隔(分)"
  type        = number
  default     = 5
}

variable "textfile_dir" {
  description = "node_exporter の textfile collector のディレクトリ(メトリクスを書く。node-exporter モジュールの textfile_directory と合わせる)"
  type        = string
  default     = "/var/lib/node_exporter/textfile"
}
