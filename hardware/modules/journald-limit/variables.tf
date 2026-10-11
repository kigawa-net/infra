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

variable "runtime_max_use" {
  description = "journald が /run/log/journal(ramdisk / tmpfs)に使う容量の上限 (RuntimeMaxUse)。例: 100M。/run を圧迫する主な原因"
  type        = string
  default     = "100M"

  validation {
    condition     = can(regex("^[0-9]+[KMGT]$", var.runtime_max_use))
    error_message = "runtime_max_use は、数字と単位(K/M/G/T)で指定する(例: 100M)。"
  }
}

variable "runtime_max_days" {
  description = "runtime journal(一時ログ)の保持日数。--vacuum-size は /var/log/journal にしか効かないため、/run 側は日数で刈る。例: 2"
  type        = number
  default     = 2

  validation {
    condition     = var.runtime_max_days > 0
    error_message = "runtime_max_days は 1 以上の整数で指定する。"
  }
}
