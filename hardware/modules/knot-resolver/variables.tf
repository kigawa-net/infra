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

variable "kresd_image" {
  type    = string
  default = "cznic/knot-resolver:latest"
}

variable "internal_domains" {
  description = "ローカルKnot DNSに転送する内部ドメインのリスト"
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
  description = "内部ドメインのフォワード先 (ローカルKnot DNS)"
  type        = string
  default     = "127.0.0.1@5353"
}

variable "coredns_ip" {
  description = "cluster.local フォワード先の CoreDNS サービス IP"
  type        = string
  default     = "10.96.0.10"
}

variable "cache_size_mb" {
  description = "メモリキャッシュサイズ (MB)"
  type        = number
  default     = 512
}

variable "dns_vip" {
  description = "DNS VIPのIPアドレス"
  type        = string
  default     = ""
}

variable "zones_reload_trigger" {
  description = <<-DESC
    knot(権威DNS)側のゾーンデータが変わるたびに値が変わるようにする
    (呼び出し側でゾーンファイルのハッシュ等を渡す)。kresdはゾーンファイル
    を直接参照せずSTUB/FORWARD経由でknotに問い合わせるだけなので、
    ゾーン内容自体はこのnull_resourceのtriggersに含まれない。これが
    無いと、ゾーン更新後もkresdが古い応答をレコードのTTL(最大24時間)
    いっぱいキャッシュし続けてしまう。
  DESC
  type        = string
  default     = ""
}
