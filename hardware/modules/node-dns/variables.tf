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

variable "dns_servers" {
  description = "内部ドメインの問い合わせ先(kresd)。VIP(10.0.0.53)に加えて、k8s4 / k8s1 の LAN アドレスを並べる。VIP は ECMP でダウンしたノードに当たることがあるため、実アドレスも持たせる"
  type        = list(string)
  default     = ["10.0.0.53", "192.168.1.120", "192.168.1.103"]
}

variable "routing_domains" {
  description = "dns_servers に向けるドメイン(systemd-resolved のルーティングドメイン)。内部の権威 DNS(knot)が答えるゾーン。それ以外の名前は、従来どおり(各ノードの netplan の DNS)で解決する"
  type        = list(string)
  default     = ["kigawa.net", "karmada.onemc.world"]
}

variable "verify_name" {
  description = "適用後の検証に使う名前。内部のアドレス(verify_prefix で始まる)に解決されなければ、設定を元に戻して失敗にする"
  type        = string
  default     = "k8s.kigawa.net"
}

variable "verify_prefix" {
  type    = string
  default = "10."
}
