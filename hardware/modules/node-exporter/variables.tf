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

variable "node_exporter_version" {
  description = "node_exporter のバージョン (例: 1.7.0)"
  type        = string
  default     = "1.7.0"
}

variable "listen_address" {
  description = "node_exporter がリッスンするアドレス"
  type        = string
  default     = ":9100"
}
