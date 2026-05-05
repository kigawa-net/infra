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

variable "internal_domains" {
  description = "内部ドメインリスト"
  type        = list(string)
  default = [
    "haproxy.kigawa.net",
    "k8s.kigawa.net",
    "mod.kigawa.net",
    "oyu.kigawa.net",
    "kizuna.kigawa.net",
    "atm10.kigawa.net",
    "kigawa.net",
    "onemc.world",
  ]
}

variable "internal_dns_ip" {
  description = "内部DNS（Knot）アドレス"
  type        = string
  default     = "127.0.0.1:5353"
}

variable "coredns_ip" {
  description = "CoreDNS サービスIP"
  type        = string
  default     = "10.96.0.10"
}

variable "cache_size_mb" {
  description = "DNSキャッシュサイズ"
  type        = number
  default     = 512
}
