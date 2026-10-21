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
  description = "true にすると、この host に MAAS の Rack コントローラーを導入する。既定は false(何もしない)。control-plane への導入は、1 台ずつ、別の PR で true にする"
  type        = bool
  default     = false
}

variable "maas_url" {
  description = "Rack が登録する Region の URL(Ingress)。host の DNS(kresd)で解決できること"
  type        = string
  default     = "https://maas.kigawa.net/MAAS"
}

variable "maas_secret" {
  description = "Region との共有 secret(Bitwarden から取得した値)。enabled が false のときは、使われない(空でよい)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "min_available_mb" {
  description = "導入前に必要な、メモリの空き(MB)。これを下回る host には、導入しない(k8s1 は 541MB で、足りない)"
  type        = number
  default     = 2000

  validation {
    condition     = var.min_available_mb >= 1000
    error_message = "min_available_mb は 1000 以上にする(control-plane を逼迫させないため)。"
  }
}
