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

variable "lan_cidr" {
  description = "Rack のポート(TFTP・proxy・NTP・HTTP・syslog)への接続を許可する、LAN の送信元(CIDR)。それ以外の送信元は DROP する(files/maas-rack-firewall.sh)"
  type        = string
  default     = "192.168.1.0/24"

  validation {
    condition     = can(cidrhost(var.lan_cidr, 0))
    error_message = "lan_cidr は、CIDR で指定する(例: 192.168.1.0/24)。"
  }
}

variable "lan_address" {
  description = "このホストの、LAN 側のアドレス(例: k8s2 は 192.168.1.20)。Rack のポートは、この宛先への接続だけを許可する(VIP 宛て、クラスタのサービス IP 宛ては、DROP)。host(SSH の接続先)とは別。enabled が true のときは、必須"
  type        = string
  default     = ""

  validation {
    condition     = var.lan_address == "" || can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", var.lan_address))
    error_message = "lan_address は、IPv4 のアドレスで指定する(例: 192.168.1.20)。"
  }
}
