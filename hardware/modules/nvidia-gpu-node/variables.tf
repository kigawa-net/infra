variable "enabled" {
  description = "false の間は何もしない(既定は無効)。ドライバ導入後は再起動が必要なので、drain してから true にして apply する"
  type        = bool
  default     = false
}

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

variable "driver_package" {
  description = "導入する NVIDIA ドライバの apt パッケージ名。GPU 世代で選ぶ(Ampere 以降は nvidia-driver-570-server など。Kepler は nvidia-driver-470)。導入前に apt-cache policy で存在を確認する"
  type        = string
  default     = "nvidia-driver-570-server"

  validation {
    condition     = can(regex("^nvidia-driver-[0-9]+(-server|-open|-server-open)?$", var.driver_package))
    error_message = "driver_package は nvidia-driver-<番号>[-server|-open|-server-open] の形式で指定する。"
  }
}

variable "install_container_toolkit" {
  description = "NVIDIA Container Toolkit を入れ、containerd に nvidia ランタイムを登録する。既定は false(クラスタの gpu-operator の Toolkit DaemonSet が行うため、二重にすると衝突する)。gpu-operator を使わないノードだけ true"
  type        = bool
  default     = false
}
