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

variable "system_max_use" {
  description = "journald が /var/log/journal に使う容量の上限 (SystemMaxUse)。例: 500M。適用時に、これを超えている古いログも、一度だけ削除する"
  type        = string
  default     = "500M"

  validation {
    condition     = can(regex("^[0-9]+[KMGT]$", var.system_max_use))
    error_message = "system_max_use は、数字と単位(K/M/G/T)で指定する(例: 500M)。"
  }
}
